//════════════════════════════════════════════════════════════════════════════
//  Tweak.xm —— SundiroSPUnlock 蓝牙无感解锁 · SpringBoard 插件（Theos）
//
//  目标：解锁不依赖官方 App。其余功能（车况遥测/小组件/深链）继续由官方
//        App 侧的 SundiroBLE.dylib 负责，本插件只干「连车 + 发四帧」。
//
//  解锁协议来自 SundiroBLE.m 第 94–198 行（49 组 (R,R3) + 32B 常量），
//  已实测可用；本文件不重新逆向，原样移植。
//
//  ★ 安全设计（SpringBoard 崩 = 注销，开机崩 = 白苹果循环，故逐条设防）：
//     1. kill-switch 文件存在 → 起蓝牙引擎前就 return，绝不碰蓝牙（含 RootHide 隐根）
//     2. 全部逻辑在**专用串行队列**（SPQueue）上，绝不在 SpringBoard 启动路径上做重活
//     3. 逐层 @try/@catch，异常绝不外泄
//     4. 失败自动重试但永不 busy-loop（退避 + 冷却）
//
//  构建：Theos + THEOS_PACKAGE_SCHEME=roothide（GitHub macOS CI）
//════════════════════════════════════════════════════════════════════════════

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

#define SPVER        @"1.2.4"
#define kKillSwitch  @"/var/mobile/Library/Preferences/com.jibamao.spsundiro.off"
#define kLogPathConf @"/var/mobile/Library/Preferences/com.jibamao.spsundiro.logpath"
#define kLogDefault  "/var/mobile/Library/Logs/sundirosp.log"
#define kPrefsSuite  @"com.jibamao.spsundiro"
#define kLogMax      (512 * 1024)

// 车名前缀（实测常量，见 SundiroBLE.m 第 77–78 行）
static const char *kNamePrefix    = "SDH-";     // 车名实测以 "SDH-" 开头

// 解锁协议常量（原样抠自 SundiroBLE.m 94–198 行）
// ── 解锁协议常量（原样抠自 SundiroBLE.m 第 94–198 行）──
static const unsigned char kUnlockConst32[32] = {
    0xB8,0xBE,0x31,0xD2,0x25,0x55,0x1F,0xF0,0x6F,0xE7,0xE6,0x0C,0xF8,0x34,0x40,0x35,
    0x30,0x19,0xE7,0xCA,0x31,0x15,0xA4,0x9C,0x98,0x8B,0x6F,0xD1,0xA5,0x81,0x0E,0xBD
};
static const struct { unsigned char r[16]; unsigned char r3[16]; } kUnlockPairs[] = {
    { {0x00, 0xAD, 0x5B, 0xEF, 0xDD, 0x59, 0x2A, 0xFB, 0xA0, 0x3B, 0x82, 0xD1, 0x20, 0x21, 0x59, 0x5F},
      {0x0E, 0x63, 0xC0, 0xFD, 0x83, 0x63, 0x5F, 0x61, 0x88, 0x6E, 0xB7, 0xDB, 0xE0, 0x87, 0x24, 0xE9} },
    { {0x02, 0x8C, 0xD6, 0x12, 0x12, 0xD7, 0x3A, 0x72, 0x9D, 0x83, 0x87, 0x7D, 0x43, 0xCE, 0xE0, 0xBE},
      {0xAA, 0x76, 0x92, 0xBC, 0x3A, 0x7F, 0xC3, 0x1F, 0x8A, 0x83, 0x50, 0x9B, 0xB8, 0x50, 0xEE, 0xA7} },
    { {0x03, 0x26, 0x1F, 0xB6, 0x2D, 0x05, 0xA0, 0xFF, 0xF6, 0x5D, 0x17, 0xB1, 0xD1, 0x99, 0x37, 0x25},
      {0x2D, 0xA2, 0x2C, 0xA0, 0x8F, 0xE2, 0xB6, 0xDE, 0xEF, 0xC0, 0xDB, 0x35, 0x60, 0x72, 0x48, 0xE2} },
    { {0x0E, 0xAB, 0x2D, 0x4C, 0x18, 0xFF, 0xFD, 0x1C, 0x8E, 0x3B, 0x70, 0x91, 0x61, 0xB8, 0xC8, 0xAA},
      {0x4B, 0xB3, 0xCC, 0x7A, 0x39, 0xC5, 0xAF, 0xB6, 0xD6, 0x39, 0x5B, 0xB9, 0x27, 0x5A, 0x17, 0xA8} },
    { {0x12, 0xC6, 0xDD, 0x25, 0x1D, 0x06, 0xD8, 0xC3, 0x39, 0xF7, 0xA9, 0x8A, 0xB9, 0x25, 0x2D, 0xEA},
      {0x7B, 0x2D, 0xB5, 0x59, 0xB5, 0xD0, 0xC8, 0x04, 0x6F, 0xE9, 0x1F, 0xBF, 0xE1, 0x4A, 0x13, 0x9B} },
    { {0x16, 0x31, 0xDE, 0x1A, 0xE2, 0xB2, 0x16, 0xD7, 0x5B, 0xB3, 0xE5, 0xAE, 0x24, 0x00, 0xE8, 0x0A},
      {0x0F, 0x66, 0x16, 0x96, 0xC3, 0xFE, 0x12, 0xB3, 0x1A, 0xF5, 0xDE, 0xB4, 0x0E, 0xC3, 0x8C, 0xAF} },
    { {0x17, 0xBF, 0x28, 0x27, 0x9C, 0x43, 0x2E, 0x56, 0x0D, 0x29, 0xCC, 0x2F, 0xFD, 0xCC, 0x35, 0xBD},
      {0x47, 0xAC, 0xDF, 0xCC, 0x8B, 0x30, 0x04, 0xDC, 0xAA, 0x38, 0x21, 0xB9, 0x17, 0xC9, 0x1E, 0xE4} },
    { {0x18, 0xA2, 0xBB, 0x6C, 0x22, 0x94, 0xA9, 0x84, 0x70, 0x12, 0xF6, 0x23, 0x12, 0xB0, 0x5C, 0x87},
      {0x4C, 0xF6, 0x6B, 0x60, 0xC3, 0x95, 0x63, 0x8D, 0x12, 0x50, 0x2E, 0xB7, 0x0D, 0xCE, 0x7D, 0x90} },
    { {0x2C, 0x79, 0x8C, 0x8F, 0x66, 0x0C, 0x4B, 0x18, 0x7D, 0xAB, 0x5C, 0xB0, 0x7B, 0x5B, 0xE7, 0x91},
      {0xA8, 0x19, 0xC2, 0xAB, 0xB0, 0xF2, 0x95, 0x9D, 0x47, 0x49, 0x5D, 0x12, 0x81, 0x38, 0x6F, 0xA1} },
    { {0x2E, 0x7D, 0x7F, 0xAE, 0x8E, 0xB3, 0x2B, 0x31, 0xD6, 0x49, 0xE0, 0x5C, 0xA3, 0xF2, 0x44, 0x33},
      {0x1D, 0xB2, 0x49, 0x8C, 0xA7, 0xEB, 0xCA, 0x44, 0xD5, 0x59, 0xAB, 0x4C, 0x43, 0x95, 0x0E, 0x43} },
    { {0x34, 0x74, 0x9B, 0x3D, 0xB3, 0xF2, 0xBD, 0x83, 0x5B, 0x6F, 0x15, 0x15, 0x87, 0xBA, 0x85, 0xEA},
      {0xA6, 0x22, 0xF6, 0xB8, 0x0B, 0x5D, 0x34, 0x0C, 0x35, 0x83, 0x57, 0x01, 0xF5, 0xFB, 0x36, 0x03} },
    { {0x35, 0x0D, 0xD4, 0xBA, 0x77, 0x99, 0xF7, 0x34, 0xF9, 0x63, 0xDC, 0x57, 0xCD, 0x62, 0x54, 0xFA},
      {0x53, 0x8A, 0x74, 0x74, 0xF9, 0xB4, 0xDE, 0xC8, 0x98, 0xBA, 0x61, 0x3A, 0xF6, 0x31, 0x0F, 0xB1} },
    { {0x53, 0x4E, 0xBC, 0x40, 0x26, 0xD0, 0xEF, 0xD5, 0x21, 0x3B, 0xDE, 0x64, 0x02, 0xB9, 0x10, 0x5E},
      {0x08, 0x80, 0x8E, 0x5D, 0xCE, 0x5E, 0xF1, 0x52, 0x70, 0x8D, 0x0D, 0xA8, 0x67, 0x8B, 0x6E, 0x57} },
    { {0x5D, 0xC2, 0xB1, 0xD7, 0x1B, 0x7B, 0x66, 0x68, 0x45, 0xDD, 0xF9, 0x25, 0x06, 0x71, 0x3F, 0x36},
      {0x1F, 0x65, 0xE8, 0xDB, 0x9A, 0x58, 0xDA, 0xF9, 0xCB, 0xE5, 0xCD, 0xE8, 0x42, 0x7C, 0x37, 0xDE} },
    { {0x5F, 0x95, 0x58, 0x59, 0xCD, 0x4F, 0xC9, 0xD1, 0xD1, 0x2A, 0x84, 0x71, 0xA6, 0x74, 0x07, 0xDF},
      {0x52, 0xEB, 0x4F, 0x03, 0x98, 0x94, 0xF9, 0x2C, 0x40, 0x8B, 0xBC, 0xBD, 0x36, 0xF3, 0xCD, 0xEE} },
    { {0x63, 0xB2, 0x22, 0x14, 0xB9, 0x10, 0xF6, 0x41, 0xDF, 0x63, 0xAB, 0x9D, 0xA6, 0xB5, 0x5D, 0x0E},
      {0xBE, 0x65, 0xB2, 0x33, 0x6F, 0x32, 0x50, 0xC1, 0x54, 0x21, 0x8C, 0x40, 0x98, 0x2D, 0xA3, 0xB7} },
    { {0x66, 0xFA, 0xFA, 0xA2, 0xBB, 0x0E, 0x35, 0xA7, 0x1E, 0x07, 0x1E, 0x07, 0xCA, 0x00, 0x9B, 0x74},
      {0xEE, 0xC7, 0x71, 0x5A, 0x8B, 0x4A, 0x7A, 0x21, 0x0B, 0xD7, 0x6A, 0x56, 0x48, 0x81, 0xEC, 0xDF} },
    { {0x67, 0x1E, 0xD9, 0x80, 0x16, 0x5A, 0x6E, 0x0C, 0x2B, 0xF3, 0x18, 0x77, 0x8C, 0x82, 0x25, 0xC9},
      {0xE1, 0xF8, 0x19, 0x43, 0x9A, 0x07, 0x15, 0x4A, 0x0F, 0x94, 0x16, 0xEA, 0x11, 0x2F, 0xFA, 0x3A} },
    { {0x68, 0xCC, 0xCD, 0x22, 0x97, 0x0A, 0x0B, 0xEC, 0xD7, 0x9B, 0x6E, 0xF7, 0x74, 0xFA, 0x47, 0x1A},
      {0x6D, 0x6C, 0xDA, 0xFF, 0x6A, 0xBF, 0xBB, 0xD4, 0x2C, 0x53, 0x74, 0x58, 0xAD, 0xEB, 0x9B, 0x7E} },
    { {0x6D, 0x48, 0xB9, 0xB0, 0x5E, 0x26, 0x26, 0x26, 0x2B, 0x84, 0x54, 0xA5, 0x76, 0xAF, 0x27, 0x32},
      {0xEB, 0x72, 0x19, 0x26, 0x48, 0x1F, 0x13, 0x57, 0x36, 0xD7, 0x76, 0x83, 0x2A, 0x39, 0x79, 0x66} },
    { {0x6D, 0x9D, 0x5D, 0x46, 0x18, 0x0C, 0x5F, 0x85, 0xAB, 0x8E, 0x90, 0x6B, 0x70, 0x8F, 0x16, 0x3F},
      {0x09, 0x7F, 0x1B, 0x7E, 0x8A, 0xA1, 0x5A, 0x46, 0x7B, 0x0A, 0x69, 0xD4, 0x72, 0x54, 0xDD, 0xEB} },
    { {0x70, 0xA9, 0xA1, 0x1F, 0x45, 0x6F, 0x9D, 0x60, 0xE6, 0x4C, 0x95, 0x7E, 0xE7, 0xD4, 0x46, 0xF8},
      {0xF0, 0x04, 0x29, 0x92, 0x05, 0x3A, 0xCB, 0xF8, 0x9F, 0x38, 0x62, 0x00, 0x0B, 0xB6, 0xB4, 0x63} },
    { {0x84, 0x73, 0xCB, 0xF3, 0x46, 0x31, 0x85, 0x12, 0x26, 0xE6, 0x4A, 0x93, 0x61, 0xC7, 0x5F, 0x31},
      {0x49, 0x03, 0xDD, 0x26, 0xF7, 0xF0, 0xF4, 0xA1, 0xE6, 0x5C, 0xC2, 0xB7, 0x03, 0xBB, 0xE7, 0x83} },
    { {0x84, 0xD1, 0xEC, 0x71, 0x80, 0x5F, 0x6E, 0x7E, 0xF9, 0xFD, 0xFB, 0xA9, 0xD8, 0xF4, 0x41, 0xC2},
      {0x74, 0xD1, 0xF8, 0x71, 0x28, 0x1A, 0x31, 0x8C, 0x24, 0x18, 0x6C, 0x56, 0x39, 0x50, 0x0A, 0xE1} },
    { {0x85, 0x91, 0xE6, 0x20, 0x16, 0x4F, 0x88, 0x02, 0x2A, 0x9C, 0x0E, 0x2F, 0x3D, 0x09, 0x39, 0xC0},
      {0xCA, 0x87, 0x2C, 0x91, 0xA0, 0x9C, 0x10, 0x4D, 0xE2, 0xAF, 0x3D, 0x82, 0x27, 0x82, 0x05, 0xD8} },
    { {0x86, 0xB3, 0x5D, 0x3E, 0x49, 0xA7, 0x8F, 0xF8, 0x8C, 0x87, 0x1C, 0x7A, 0xC4, 0xFE, 0xBE, 0x58},
      {0x40, 0x9D, 0xC7, 0xA3, 0x6C, 0x81, 0x07, 0x80, 0x9E, 0x2F, 0x96, 0xC4, 0x21, 0x10, 0x4E, 0x3F} },
    { {0x88, 0x3E, 0x8D, 0xDD, 0x6B, 0x1C, 0x6E, 0x5F, 0x09, 0xAE, 0x02, 0xAB, 0xA5, 0x3D, 0x91, 0x8D},
      {0x2C, 0x3E, 0xB9, 0x57, 0xBD, 0xDE, 0x93, 0xB2, 0x15, 0xF4, 0xF4, 0x66, 0x2E, 0x02, 0xD1, 0xF6} },
    { {0x8A, 0x8D, 0x72, 0x6B, 0x11, 0x01, 0x69, 0xC7, 0xF7, 0x12, 0xD9, 0xBC, 0xE1, 0x7F, 0x66, 0x2E},
      {0x15, 0x64, 0xF4, 0x0C, 0xBA, 0x8E, 0x6E, 0x6E, 0x3A, 0x50, 0x53, 0x2B, 0x94, 0xD9, 0xA4, 0x11} },
    { {0x8D, 0x62, 0x21, 0x6C, 0x65, 0xD7, 0xD2, 0x4D, 0xDF, 0x1E, 0xB9, 0x76, 0x80, 0xDF, 0x1B, 0xAD},
      {0x18, 0x40, 0xC6, 0xF2, 0xEB, 0x42, 0x3A, 0x97, 0xE6, 0xF6, 0x68, 0x9A, 0x89, 0xDF, 0x56, 0x4D} },
    { {0x92, 0x4D, 0x68, 0xE3, 0x9C, 0x35, 0xBD, 0xDD, 0xC0, 0xF7, 0x86, 0x54, 0x53, 0x44, 0x80, 0x57},
      {0x43, 0xCC, 0xD3, 0x12, 0xED, 0x01, 0x1A, 0x23, 0x62, 0x11, 0xAD, 0x2F, 0x61, 0xC2, 0xEF, 0x32} },
    { {0x94, 0x7F, 0x6F, 0x3D, 0x61, 0xEF, 0x22, 0x21, 0xE4, 0x54, 0x53, 0xEC, 0x52, 0x42, 0xF8, 0x9B},
      {0xE6, 0xFD, 0xCE, 0xB8, 0xE5, 0xF5, 0x10, 0x99, 0x96, 0xC9, 0x54, 0xA0, 0x18, 0x13, 0x5D, 0x9A} },
    { {0x9A, 0xD2, 0x13, 0x17, 0xE9, 0xBC, 0xEE, 0x41, 0x8A, 0x3B, 0x2D, 0x32, 0x46, 0x88, 0x8D, 0x47},
      {0x74, 0x4E, 0x12, 0x5E, 0x64, 0xDE, 0xAC, 0x3D, 0x2B, 0xC5, 0xA4, 0xB0, 0x0D, 0xD2, 0xDF, 0x19} },
    { {0x9B, 0xDC, 0x98, 0x1B, 0x6E, 0x4B, 0xC8, 0x5E, 0x1C, 0x2B, 0xB9, 0xDD, 0xEE, 0x0F, 0x9A, 0x97},
      {0x73, 0x53, 0x67, 0xB0, 0x68, 0xAE, 0xB7, 0x67, 0x91, 0xE6, 0x71, 0x70, 0xC8, 0xCB, 0xEF, 0x64} },
    { {0xA0, 0x89, 0x21, 0x07, 0x21, 0x1F, 0x06, 0x87, 0x24, 0xD2, 0x38, 0xD1, 0x45, 0xC8, 0x29, 0xBC},
      {0xDE, 0x56, 0x23, 0x22, 0x45, 0x54, 0x29, 0xA7, 0xB5, 0xF3, 0x7E, 0x98, 0x9E, 0xF1, 0x0E, 0xAF} },
    { {0xA3, 0x83, 0x85, 0x53, 0xE9, 0xBC, 0x08, 0x6B, 0x01, 0x5A, 0xD7, 0x48, 0xF5, 0x5A, 0xBF, 0x14},
      {0x49, 0xFD, 0x37, 0x27, 0x17, 0x3F, 0xA8, 0xD6, 0x0A, 0xA6, 0xF7, 0x5E, 0x5A, 0x8E, 0x68, 0x6F} },
    { {0xAE, 0xE3, 0x0B, 0x5B, 0x79, 0x4A, 0x6D, 0x95, 0x64, 0x70, 0xDB, 0xE0, 0x6B, 0xB1, 0x2D, 0x4E},
      {0x4E, 0x23, 0x4A, 0xD6, 0xA0, 0x48, 0x5D, 0xB7, 0x18, 0x51, 0x9B, 0x06, 0xDC, 0x76, 0x2F, 0x4F} },
    { {0xB4, 0x8A, 0xD8, 0x6F, 0xC3, 0xF3, 0x76, 0x86, 0x10, 0xBB, 0xD9, 0x95, 0xF0, 0x9A, 0x6E, 0x58},
      {0x35, 0x59, 0x54, 0x7C, 0x79, 0x94, 0x86, 0xF5, 0xE6, 0x36, 0x26, 0x60, 0xC5, 0x65, 0xD8, 0x25} },
    { {0xBA, 0x94, 0x64, 0x15, 0xF8, 0x72, 0xFE, 0xAA, 0x58, 0xBD, 0x00, 0xF8, 0x04, 0xA7, 0x9D, 0x62},
      {0x15, 0x64, 0xF4, 0x0C, 0xBA, 0x8E, 0x6E, 0x6E, 0x3A, 0x50, 0x53, 0x2B, 0x94, 0xD9, 0xA4, 0x11} },
    { {0xBA, 0x95, 0x65, 0xF7, 0xF8, 0x0D, 0x23, 0x8A, 0xE3, 0xB0, 0xF3, 0x8A, 0xF4, 0x3D, 0xE3, 0x72},
      {0x9B, 0x56, 0x88, 0xC5, 0xA9, 0xA1, 0xC5, 0xC2, 0xF5, 0xF5, 0xCD, 0x1C, 0x9C, 0xF1, 0x0B, 0x9C} },
    { {0xCD, 0xCF, 0x67, 0xD8, 0xE5, 0x9D, 0x19, 0x2C, 0x54, 0x54, 0x0F, 0x26, 0x36, 0x5C, 0xA3, 0x4A},
      {0x12, 0x89, 0xB0, 0x50, 0x51, 0x2E, 0x8B, 0x31, 0x8D, 0x72, 0x37, 0xBA, 0x92, 0x6D, 0xEA, 0x0A} },
    { {0xD2, 0x97, 0xD7, 0x59, 0x2A, 0xA6, 0x7E, 0xAC, 0x4A, 0x6B, 0xEB, 0x49, 0x9E, 0x29, 0x77, 0x6E},
      {0x63, 0xFF, 0xF9, 0x85, 0x01, 0x43, 0x36, 0x99, 0xA6, 0x65, 0x67, 0x8F, 0xA5, 0xF8, 0x2C, 0x28} },
    { {0xD5, 0xB8, 0xDE, 0x8C, 0x4A, 0x90, 0x2D, 0xB9, 0x6E, 0xE7, 0x5F, 0xE1, 0x08, 0xDF, 0xE6, 0xDB},
      {0xE6, 0x66, 0x51, 0xCD, 0xC6, 0x2C, 0x6C, 0x3B, 0x43, 0x5D, 0x8D, 0x6A, 0x35, 0x8E, 0x36, 0xC0} },
    { {0xDB, 0x9C, 0x1E, 0xF4, 0xE2, 0xBB, 0x97, 0x5A, 0xF7, 0x01, 0xA4, 0xCE, 0xD5, 0x31, 0x6E, 0x77},
      {0x74, 0x4E, 0x12, 0x5E, 0x64, 0xDE, 0xAC, 0x3D, 0x2B, 0xC5, 0xA4, 0xB0, 0x0D, 0xD2, 0xDF, 0x19} },
    { {0xE3, 0xCE, 0x1D, 0x34, 0x44, 0xE7, 0x3A, 0x99, 0x49, 0x4E, 0x39, 0x9B, 0xB5, 0x25, 0x24, 0x2B},
      {0x07, 0xA6, 0xD5, 0x3A, 0xCE, 0x57, 0x33, 0xE2, 0xEC, 0x24, 0x39, 0x98, 0x99, 0xAC, 0x24, 0x44} },
    { {0xEB, 0x98, 0x21, 0x44, 0x7A, 0xF3, 0x8B, 0x81, 0xB8, 0x7A, 0x76, 0xD4, 0xDB, 0x2B, 0xEC, 0xD7},
      {0xB8, 0x36, 0x21, 0x23, 0xA6, 0xF0, 0xEE, 0xD5, 0x02, 0x07, 0x10, 0x82, 0xA6, 0x28, 0x65, 0x44} },
    { {0xEC, 0x41, 0xCC, 0xAA, 0xC1, 0xAF, 0xFE, 0x14, 0xE5, 0xDC, 0xAA, 0x70, 0x7D, 0x7A, 0x43, 0x9E},
      {0xF6, 0x50, 0x7F, 0xC7, 0xE5, 0x28, 0x8E, 0x4B, 0xEC, 0x96, 0xB3, 0x4C, 0x43, 0x65, 0xD4, 0x47} },
    { {0xEE, 0x40, 0x37, 0xA5, 0x56, 0x8A, 0x11, 0x43, 0xC3, 0xB0, 0x95, 0xAD, 0x6C, 0x4D, 0xDA, 0x8E},
      {0xF9, 0xF7, 0x78, 0xAE, 0x24, 0xEB, 0x7F, 0xC0, 0xFA, 0x15, 0xE4, 0x40, 0x93, 0x26, 0x70, 0xDA} },
    { {0xF8, 0x9D, 0x42, 0x13, 0x6A, 0x91, 0xBD, 0xD8, 0x24, 0x40, 0x0C, 0x78, 0x84, 0xFA, 0x13, 0xE3},
      {0xD4, 0x8E, 0xEB, 0x75, 0x5C, 0xCE, 0xEE, 0xFD, 0xE2, 0x6F, 0x1C, 0x8F, 0x3A, 0x11, 0xD8, 0x51} },
    { {0xFB, 0x57, 0x20, 0x26, 0x73, 0xF1, 0x68, 0xE9, 0x74, 0x7C, 0x7E, 0x2E, 0xBD, 0xE4, 0x20, 0xC4},
      {0xEA, 0xE3, 0xB5, 0x3B, 0x3E, 0x44, 0x50, 0x43, 0x81, 0x69, 0x5B, 0xCE, 0x2C, 0xE9, 0xC0, 0x92} },
};
static const NSUInteger kUnlockPairCount = 49;


//────────────── 通用工具：专用串行队列 / 单调时钟 / 多根路径探测 ──────────────
// ★ B1：必须是**串行**队列。头部注释一直声明"串行"，但 1.1.6 实际用的是
//   dispatch_get_global_queue（并发）—— _step/_pick/_wr/_nt/_linkAt 等共享状态
//   被 CBCentralManager 回调、retryLater、SPTick、directBegin 的定时块并发读写。
//   最危险的组合：两个 directBegin 并发 → _pick 前进两次 → onCarFrame 第 2 步取到的
//   R3 与第 1 步的 R 不是同一组 → 解锁直接失败。
static dispatch_queue_t SPQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.jibamao.spsundiro.btq", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ★ C3：单调时钟。墙钟（NSDate.timeIntervalSince1970）被 NTP 校正或用户手动回拨时，
//   now - _lastAt 会变成负数 → 20 秒冷却 / 60 秒扫描冷却 被锁死到时钟追平为止。
static NSTimeInterval SPNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (NSTimeInterval)ts.tv_sec + (NSTimeInterval)ts.tv_nsec / 1e9;
}

// ★ C1：RootHide 的隐根是 **动态 UUID** 目录（每次重新越狱都会变），绝不能硬编码。
//   插件 dylib 没有 vroot，读的是真实 /var/mobile/...；而终端类工具（带 vroot）创建的
//   文件会落进 .../AppGroup/.jbroot-<UUID>/var/mobile/... 镜像 —— 两侧不一致会让
//   安全阀静默失效。此处把所有可能的根都列出来逐一探测。
static NSArray<NSString *> *SPRoots(void) {
    NSMutableArray *a = [NSMutableArray arrayWithObjects:@"", @"/var/jb", nil];
    @try {
        NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
        for (NSString *d in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil]) {
            if ([d hasPrefix:@".jbroot-"])
                [a addObject:[base stringByAppendingPathComponent:d]];
        }
    } @catch (NSException *e) { /* 探测失败不影响真实根 */ }
    return a;
}

// 返回第一个真实存在的路径（real 形如 /var/mobile/Library/Preferences/xxx）
static NSString *SPFind(NSString *real) {
    for (NSString *r in SPRoots()) {
        NSString *p = r.length ? [r stringByAppendingString:real] : real;
        if (access(p.fileSystemRepresentation, F_OK) == 0) return p;
    }
    return nil;
}

// 日志候选路径 = 多根 × 相对路径（顺序保持 1.1.6 原有优先级）
static NSArray<NSString *> *SPLogProbePaths(void) {
    NSArray *rel = @[
        @"/var/mobile/Library/Logs/sundirosp.log",
        @"/var/mobile/Library/Preferences/com.jibamao.spsundiro.log",
        @"/var/mobile/Documents/sundirosp.log",
        @"/tmp/sundirosp.log",
        @"/var/tmp/sundirosp.log",
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *r in SPRoots())
        for (NSString *x in rel)
            [out addObject:(r.length ? [r stringByAppendingString:x] : x)];
    return out;
}


//──────────────────────────── 日志 ────────────────────────────
static char gLogPath[512];

// ★ D1：1.1.6 会把**每一行**同时写进 6 个候选文件，而轮转只覆盖其中一个 ——
//   其余 5 个无界增长；且每行 6 次 fopen/fwrite/fflush/fclose 是串在解锁关键路径上的
//   I/O（车回帧 → 打日志 → 写下一帧）。现改为：探测出**第一个真可写**的路径锁定，
//   只写它；写失败时重新探测一次（保留原容错能力）。
static void SPLogInit(void) {
    if (gLogPath[0]) return;
    // ① 允许配置文件覆盖（同样做多根探测）
    NSString *conf = SPFind(kLogPathConf);
    if (conf) {
        FILE *f = fopen(conf.fileSystemRepresentation, "r");
        if (f) {
            char tmp[512] = {0};
            if (fgets(tmp, sizeof tmp, f)) {
                size_t n = strlen(tmp);
                while (n && (tmp[n-1]=='\n'||tmp[n-1]=='\r')) tmp[--n]=0;
                if (n) snprintf(gLogPath, sizeof gLogPath, "%s", tmp);
            }
            fclose(f);
        }
    }
    // ② 未指定 → 探测第一个可写候选
    if (!gLogPath[0]) {
        for (NSString *p in SPLogProbePaths()) {
            FILE *f = fopen(p.fileSystemRepresentation, "a");
            if (!f) continue;
            fclose(f);
            snprintf(gLogPath, sizeof gLogPath, "%s", p.fileSystemRepresentation);
            break;
        }
    }
    if (!gLogPath[0]) snprintf(gLogPath, sizeof gLogPath, "%s", kLogDefault);
}

static void SPLog(NSString *tag, NSString *fmt, ...) {
    @try {
        if (!gLogPath[0]) SPLogInit();
        struct stat st;
        if (stat(gLogPath, &st) == 0 && st.st_size > kLogMax) {
            char bak[600]; snprintf(bak, sizeof bak, "%s.1", gLogPath);
            rename(gLogPath, bak);
        }
        // ★★★ 必须用 Objective-C 格式化：C 的 vsnprintf 不认识 %@（那属于 ObjC），
        //   会把 %@ 退化成 @，并让后续参数整体错位 ——
        //   实测导致 pid/uid 变乱码、异常内容整条丢失（日志只剩 "启动异常: @"）。
        va_list ap; va_start(ap, fmt);
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!body) return;

        time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
        char ts[32]; strftime(ts, sizeof ts, "%m-%d %H:%M:%S", &tm);
        NSString *line = [NSString stringWithFormat:@"%s [%@] %@", ts, tag, body];

        // ① NSLog 一定写系统日志（Console 可读），沙盒拦不住
        NSLog(@"[SundiroSPUnlock] %@", line);

        // ② 文件日志：只写已锁定的单一路径（★ D1）
        NSData *db = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSData *nl = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
        FILE *f = fopen(gLogPath, "a");
        if (!f) {                                   // 路径失效 → 重新探测一次
            gLogPath[0] = 0; SPLogInit();
            f = fopen(gLogPath, "a");
        }
        if (f) {
            fwrite(db.bytes, 1, db.length, f);
            fwrite(nl.bytes, 1, nl.length, f);
            fflush(f); fclose(f);
        }
    } @catch (NSException *e) { /* 日志绝不抛 */ }
}

static BOOL SPFlag(NSString *k, BOOL def) {
    @try {
        NSNumber *v = [[[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite] objectForKey:k];
        return v ? v.boolValue : def;
    } @catch (NSException *e) { return def; }
}

// App 侧把学到的车写进它自己的域 "sb.vehicle"，同以 mobile 用户读得到
//════════════ 读取官方 App 学到的车辆 UUID ════════════
// ★ 关键：App 用的是 [NSUserDefaults standardUserDefaults]（见 SundiroBLE.m:389/428），
//   即存在 App 自己的容器里：
//     /var/mobile/Containers/Data/Application/<App-UUID>/Library/Preferences/com.sundirohonda.app.plist
//   从 SpringBoard **不能**用 initWithSuiteName: 直接读到（那是 app 域，不是 suite）。
//   1.0.7 日志实测：三个 suite 全部读空，就是这个原因。
//   下面两条路：① cfprefsd 跨用户域读 ② 直接扫文件系统（jbroot 下路径经 systemhook 重定向）

static NSString *const kAppBundleID = @"com.sundirohonda.app";
static NSString *const kAppGroupID2 = @"group.com.carbit.edrive.honda";

static id SPReadPref(NSString *key) {
    // ① cfprefsd：以 AnyUser/AnyHost 读 app 域
    @try {
        CFPropertyListRef v = CFPreferencesCopyValue(
            (__bridge CFStringRef)key,
            (__bridge CFStringRef)kAppBundleID,
            kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        if (v) {
            id r = (__bridge_transfer id)v;
            if ([r isKindOfClass:NSString.class] && [r length]) {
                SPLog(@"probe", @"cfprefsd 命中 %@ = %@", key, r);
                return r;
            }
        }
    } @catch (NSException *e) { }

    // ② 直接扫文件系统（App 容器 + App Group）
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray *dirs = @[
            @"/var/mobile/Containers/Data/Application",
            @"/var/mobile/Containers/Shared/AppGroup",
        ];
        NSArray *plists = @[ @"com.sundirohonda.app", kAppGroupID2 ];
        for (NSString *base in dirs) {
            NSArray *subs = [fm contentsOfDirectoryAtPath:base error:nil];
            for (NSString *sub in subs) {
                for (NSString *pn in plists) {
                    NSString *p = [NSString stringWithFormat:
                        @"%@/%@/Library/Preferences/%@.plist", base, sub, pn];
                    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
                    if (!d) continue;
                    id v = d[key];
                    if ([v isKindOfClass:NSString.class] && [v length]) {
                        SPLog(@"probe", @"扫描命中 %@ ← %@", key, p);
                        return v;
                    }
                }
            }
        }
        SPLog(@"probe", @"★ App 容器里也没找到 %@（App 可能从未连过车）", key);
    } @catch (NSException *e) { SPLog(@"probe", @"扫盘异常: %@", e.reason); }
    return nil;
}

static NSString *SPKnownVehicleUUID(void) {
    NSString *u = SPReadPref(@"sb.vehicle");
    if (!u) u = SPReadPref(@"vehicle");
    if (u) SPLog(@"probe", @"车辆 UUID = %@", u);
    return u;
}

static NSString *SPKnownVehicleName(void) {
    return SPReadPref(@"sb.vehicle.name");
}

//──────────────────────── 造帧（与 App 侧逐行一致）────────────────────────
static NSData *SPFrame(unsigned char cmd, unsigned char seq, unsigned char status,
                       unsigned char tag, const unsigned char *pay, NSUInteger payLen) {
    NSMutableData *d = [NSMutableData data];
    unsigned char h[7] = {0x55, 0x55, (unsigned char)(10 + payLen), cmd, seq, status, tag};
    [d appendBytes:h length:7];
    if (pay && payLen) [d appendBytes:pay length:payLen];
    unsigned char x = 0;
    const unsigned char *b = (const unsigned char *)d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) x ^= b[i];
    [d appendBytes:&x length:1];
    unsigned char t[2] = {0xAA, 0xAA};
    [d appendBytes:t length:2];
    return d;
}

//════════════════════════════ 解锁器 ════════════════════════════
@interface SPUnlocker : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *cm;
@property (nonatomic, strong) CBPeripheral     *car;
@property (nonatomic, strong) CBCharacteristic *wr;      // FFF6
@property (nonatomic, strong) CBCharacteristic *nt;      // FFF1
@property (nonatomic, strong) NSString         *carUUID;
@property (nonatomic, strong) NSString         *carName;
@property (nonatomic, assign) NSInteger         step;    // 0 空闲，1..4 已发第 N 帧
@property (nonatomic, assign) NSUInteger        pick;    // 配对表游标
@property (nonatomic, assign) NSTimeInterval    lastAt;  // 冷却起点
@property (nonatomic, assign) NSTimeInterval    startAt;
@property (nonatomic, assign) NSTimeInterval    doneLink;
@property (nonatomic, assign) NSTimeInterval    linkAt;   // 本链路握手时刻（CBPeripheral 没这属性，自己记）
@property (nonatomic, assign) NSInteger         connects;
@property (nonatomic, assign) NSInteger         unlocks;
@property (nonatomic, assign) BOOL              scanning;
@property (nonatomic, assign) BOOL              armed;
@property (nonatomic, assign) NSTimeInterval    nextScanAt;   // 扫描冷却
@property (nonatomic, assign) long              ticks;        // 心跳计数
@property (nonatomic, assign) NSTimeInterval    backoff;      // 重连退避（成功即复位）
@property (nonatomic, assign) BOOL              connecting;   // ★ B2：连接请求已下发（原子守卫）
@property (nonatomic, assign) NSTimeInterval    connAt;       // ★ 1.2.2：连接请求下发时刻（守卫卡死判定用）
@property (nonatomic, assign) NSTimeInterval    guardLogAt;   // ★ 1.2.2：守卫早退日志限流
@property (nonatomic, assign) NSUInteger        round;        // ★ A1：解锁轮次号（看门狗代际校验）
@property (nonatomic, assign) NSInteger         stallRetries; // ★ A1：本链路自愈重发次数
@property (nonatomic, assign) BOOL              saw42;        // ★ 1.2.4：本轮是否见过 42 帧（车端受理凭证）
@property (nonatomic, assign) NSTimeInterval    no42At;       // ★ 1.2.4：上次因未见42主动换链时刻（60秒节流）
@end

static void SPTick(SPUnlocker *u);   // ★ D2：start 里要启动常驻驱动，需前向声明

@implementation SPUnlocker

- (instancetype)init {
    if ((self = [super init])) { _step = 0; _pick = 0; }
    return self;
}

- (void)start {
    if (_cm) return;
    // ★ 只在 SpringBoard 里起蓝牙引擎；其它宿主（对照用的 App）只留一颗信标
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (![bid.lowercaseString isEqualToString:@"com.apple.springboard"]) {
        SPLog(@"boot", @"宿主 %@ 非 SpringBoard —— 只留信标，不起蓝牙引擎", bid);
        return;
    }
    // ★★★ 绝不能带 CBCentralManagerOptionRestoreIdentifierKey！
    //   实测（1.0.4 日志）在 SpringBoard 里会抛：
    //     NSInternalInconsistencyException: State restoration of CBCentralManager
    //     is only allowed for applications that have specified the
    //     "bluetooth-central" background mode
    //   iOS 只在 Info.plist 声明了 bluetooth-central 后台模式的 App 里允许状态恢复；
    //   SpringBoard 是系统常驻进程，既没这个 key、也**根本不需要**状态恢复
    //   （进程永不退出，无需被系统重新拉起）。这是从 App 版移植过来的历史包袱。
    _backoff = 1.0;      // ★ 退避初值。绝不依赖 ivar 默认 0 —— 否则 MIN(0,30)=0 秒，会疯狂重连
    NSDictionary *opt = @{ CBCentralManagerOptionShowPowerAlertKey: @NO };
    _cm = [[CBCentralManager alloc] initWithDelegate:self
                                               queue:SPQueue()          // ★ B1：专用串行队列
                                             options:opt];
    SPLog(@"boot", @"SPUnlocker v%@ 启动 pid=%d uid=%d", SPVER, getpid(), getuid());
    SPTick(self);        // ★ D2：只有真起了蓝牙引擎才启动常驻驱动（非 SB 宿主不再空转定时器）
}

//──────────────────────── 扫描 / 连接 ────────────────────────
- (void)beginScan:(NSString *)why {
    if (!_cm || _cm.state != CBManagerStatePoweredOn || _scanning) return;
    NSTimeInterval now = SPNow();                  // ★ C3：单调时钟
    if (now < _nextScanAt) return;                 // 冷却期内不扫，省电
    _nextScanAt = now + 60.0;                      // 一轮扫完歇 60 秒（1.0.7 曾为加速实测改成 20，P1 恢复）
    // ★ 不限定服务 UUID：无法确认车在广播里一定带 FFF0
    //   （App 版靠 retrieve 已知 UUID 连车，**从未真正跑过扫描**，所以这点未经验证）。
    //   改为全扫，再用「已知 UUID」或「名字前缀 SDH-」双重匹配（见 didDiscoverPeripheral）。
    NSDictionary *o = @{ CBCentralManagerScanOptionAllowDuplicatesKey: @NO };
    [_cm scanForPeripheralsWithServices:nil options:o];
    _scanning = YES;
    SPLog(@"link", @"开始扫描（全设备，%@）", why);
    // 扫描窗口 25 秒，到点停
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                   SPQueue(), ^{                                   // ★ B1
        [self stopScan:@"窗口结束"];
    });
}

- (void)stopScan:(NSString *)why {
    if (!_scanning) return;
    _scanning = NO;
    [_cm stopScan];
    SPLog(@"link", @"停止扫描（%@）", why);
}

- (void)tryConnect {
    if (!_cm || _cm.state != CBManagerStatePoweredOn) return;
    if (!_car) {
        // 先用 App 学到的 UUID retrieve（不解锁时也能少扫一轮）
        // 名字也读出来 —— 万一 UUID 拿不到，还有名字可匹配
        if (!_carName.length) {
            NSString *nm = SPKnownVehicleName();
            if (nm.length) { _carName = nm; SPLog(@"probe", @"已知车名 = %@", nm); }
        }
        // ★ C2：只读一次。1.1.6 缺这个前置判断 —— _car 停在 nil 时，SPTick 每 15 秒
        //   就会重跑一次 SPKnownVehicleUUID()（遍历 App 容器 + AppGroup 全目录，约 200 次文件读）。
        if (!_carUUID.length) {
            NSString *u = SPKnownVehicleUUID();
            if (u.length) _carUUID = u;
        }
        if (_carUUID.length) {
            NSUUID *nid = [[NSUUID alloc] initWithUUIDString:_carUUID];
            if (nid) {
                NSArray *found = [_cm retrievePeripheralsWithIdentifiers:@[nid]];
                SPLog(@"probe", @"retrieve 已知 UUID 命中 %lu 个外设", (unsigned long)found.count);
                if (found.count) [self adopt:found.firstObject why:@"retrieve"];
            } else {
                SPLog(@"probe", @"★ UUID 字符串非法: %@", _carUUID);
            }
        }
    }
    if (!_car) { [self beginScan:@"还没有车对象"]; return; }
    // ★ B2：_car.state 要等 CoreBluetooth 异步处理后才变 Connecting，而三个调用者
    //   （状态回调 / retryLater / SPTick）可能同时通过状态守卫 → 同秒双发 connect。
    //   1.1.6 日志铁证：16:52:40 两条「连接请求」，紧接着 16:52:44 Failed to encrypt。
    if (_connecting) {
        // ★ 1.2.3：分档限流 —— 只对「卡死特征」高声告警，健康挂起只低频记录。
        //   （1.2.2 原来只按 60 秒一刀切，未区分两种情形，自我变成了噪声源）
        //   判据来自 1.2.2 真机实证（2026-10-11 00:03–01:04）：
        //     · 外设状态=1（Connecting）⇒ iOS 仍持有 pending connect，**健康**，等车唤醒即可；
        //       1.2.2 曾在一次 61 分钟的健康挂起里刷了 64 条（≈48 条/小时），淹没真实事件，
        //       并会加速 512 KB 日志轮转，把可用于诊断的历史挤掉。
        //     · 外设状态=0（Disconnected）而守卫仍挂着 ⇒ **卡死**（蓝牙关闭丢回调的那一类）。
        //   本条早退仍是零控制流改动：只决定「打不打日志」，不影响任何行为。
        NSTimeInterval gnow = SPNow();
        NSTimeInterval held = _connAt > 0 ? gnow - _connAt : -1.0;
        if (_car.state == CBPeripheralStateDisconnected) {
            if (held > 30.0 && gnow - _guardLogAt > 60.0) {       // 卡死：高声、60 秒限流
                _guardLogAt = gnow;
                SPLog(@"link", @"★ 守卫疑似卡死（已挂 %.0f 秒，外设未在连接，状态=%ld）",
                      held, (long)_car.state);
            }
        } else if (gnow - _guardLogAt > 600.0) {                  // 健康挂起：10 分钟一条，中性措辞
            _guardLogAt = gnow;
            SPLog(@"link", @"连接请求仍在挂起（已挂 %.0f 秒，外设状态=%ld）",
                  held, (long)_car.state);
        }
        return;
    }
    if (_car.state == CBPeripheralStateConnected || _car.state == CBPeripheralStateConnecting) return;
    _connecting = YES;
    _connAt = SPNow();                                        // ★ 1.2.2：记下发时刻
    SPLog(@"link", @"连接请求 -> %@", _carName ?: _carUUID ?: @"(未知)");
    [_cm connectPeripheral:_car options:nil];
}

- (void)adopt:(CBPeripheral *)p why:(NSString *)why {
    if (!p.identifier) return;
    _car = p;
    _carUUID = p.identifier.UUIDString;
    if (p.name.length) _carName = p.name;
    p.delegate = self;
    [[[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite] setObject:_carUUID forKey:@"vehicle"];
    SPLog(@"link", @"认车 %@ (%@) — %@", _carName ?: @"(无名)", _carUUID, why);
}

//──────────────────────── 直发四帧（原样移植）────────────────────────
// ★ A1：每步看门狗。1.1.6 只给第 1 帧设了 3 秒超时，而实测最慢 f1→f2 正好 3.0 秒 ——
//   零余量；更要命的是 onCarFrame 推进到 2/3/4 之后**没有任何超时**，而三条恢复路径
//   全被堵死（directBegin 的 _step!=0 早退 / SPTick 的 step==0 分支 / 唯一复位点只在断线），
//   → 握手中途卡死就**永久停摆**，只能等车自己把链路断掉。
- (void)armWatchdog:(NSInteger)expect {
    NSUInteger gen = _round;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   SPQueue(), ^{
        if (self->_round != gen)   return;   // 已进入新一轮 → 旧定时器作废
        if (self->_step != expect) return;   // 已推进       → 无需处理
        SPLog(@"direct", @"★ 第 %ld 帧后 8 秒无车回帧 —— 释放本轮", (long)expect);
        self->_step = 0;
        self->_lastAt = 0;                   // ★ 清冷却：失败不该吃掉 20 秒窗口
        if (self->_stallRetries < 2 &&
            self->_car.state == CBPeripheralStateConnected && self->_wr) {
            self->_stallRetries++;
            SPLog(@"direct", @"★ 链路仍在 —— 立即重发（自愈第 %ld 次）", (long)self->_stallRetries);
            [self directBegin];
        }
    });
}

- (void)directBegin {
    @try {
        if (!SPFlag(@"unlock", YES)) return;
        if (_step != 0) return;
        if (!_wr || _car.state != CBPeripheralStateConnected) return;
        NSTimeInterval now = SPNow();                  // ★ C3：单调时钟
        // 同一条链路已完整发过一轮 → 不再重复（车早就解开了）
        if (_doneLink > 0 && _linkAt > 0 && fabs(_doneLink - _linkAt) < 0.001) return;
        // 冷却 20 秒：只作**同链路**防抖兜底。链路一断 _lastAt 即归零（见 didDisconnectPeripheral），
        // 所以新链路永远不会被上一轮的冷却挡住。本条排在 _doneLink 守卫之后，不会在
        // 「本轮已发完」的 15 秒轮询里刷屏。
        // ★ 1.2.1：这个分支原来零日志 —— 正是它把「按一次不开、要按两次」藏了整整一个版本。
        if (_lastAt > 0 && now - _lastAt < 20.0) {
            SPLog(@"direct", @"直发被同链路冷却挡住（还剩 %.1f 秒）—— 交给下一拍补发",
                  20.0 - (now - _lastAt));
            return;
        }

        _lastAt = now;
        _startAt = now;
        _round++;                                      // ★ A1：新一轮 → 作废上一轮的看门狗
        _saw42 = NO;                                   // ★ 1.2.4：新一轮开始，重置 42 凭证
        const unsigned char *R = kUnlockPairs[_pick % kUnlockPairCount].r;
        _pick++;
        unsigned char pay[48];
        memcpy(pay, R, 16);
        memcpy(pay + 16, kUnlockConst32, 32);
        _step = 1;
        [_car writeValue:SPFrame(0x02, 0x00, 0x01, 0xFE, pay, 48)
      forCharacteristic:_wr
                   type:CBCharacteristicWriteWithResponse];
        SPLog(@"direct", @"-> 解锁帧 1/4（配对 #%lu）", (unsigned long)((_pick - 1) % kUnlockPairCount));

        [self armWatchdog:1];                          // ★ A1（原 3 秒一次性超时 → 统一的每步看门狗）
    } @catch (NSException *e) { SPLog(@"direct", @"directBegin 异常: %@", e.reason); _step = 0; }
}

- (void)onCarFrame:(NSData *)d {
    @try {
        if (_step == 0) return;
        NSUInteger L = d.length;
        if (L == 42) _saw42 = YES;   // ★ 1.2.4：车端受理凭证 —— 整轮见过 42 才视为会话被接受
        if (_step == 1 && (L == 26 || L == 42)) {
            _step = 2;
            [_car writeValue:SPFrame(0x00, 0x01, 0x00, 0xFA, NULL, 0)
          forCharacteristic:_wr type:CBCharacteristicWriteWithResponse];
            SPLog(@"direct", @"-> 解锁帧 2/4");
            [self armWatchdog:2];                      // ★ A1
            return;
        }
        if (_step == 2 && (L == 42 || L == 26)) {
            const unsigned char *R3 =
                kUnlockPairs[(_pick + kUnlockPairCount - 1) % kUnlockPairCount].r3;
            _step = 3;
            [_car writeValue:SPFrame(0x02, 0x02, 0x03, 0xFA, R3, 16)
          forCharacteristic:_wr type:CBCharacteristicWriteWithResponse];
            SPLog(@"direct", @"-> 解锁帧 3/4");
            [self armWatchdog:3];                      // ★ A1
            return;
        }
        if (_step == 3 && L == 26) {
            _step = 4;
            [_car writeValue:SPFrame(0x00, 0x03, 0x04, 0xFA, NULL, 0)
          forCharacteristic:_wr type:CBCharacteristicWriteWithResponse];
            SPLog(@"direct", @"-> 解锁帧 4/4");
            [self armWatchdog:4];                      // ★ A1

            // ★ 1.2.4：完成门禁 —— 42 帧 = 车端受理凭证。若整轮从未见 42
            //   （16:04 真机铁证：26/26/26，按车钮无反应），本轮不得标完成；
            //   清冷却让心跳拍补发，并按 60 秒节流主动换链（正是当时自然恢复的路径）。
            if (!_saw42) {
                _step = 0; _lastAt = 0;                // 不标完成、清冷却，允许同链路补发
                NSTimeInterval gnow = SPNow();
                if (gnow - _no42At > 60.0) {           // 换链节流：60 秒最多一次
                    _no42At = gnow;
                    SPLog(@"direct", @"★★ 四帧发完但全程未见 42 —— 车端未受理，1.5 秒后主动换链重来");
                    NSUInteger gen = _round;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(1.5 * NSEC_PER_SEC)),
                                   SPQueue(), ^{
                        if (self->_round != gen) return;               // 已被新流程接管
                        if (self->_car.state != CBPeripheralStateConnected) return;
                        [self->_cm cancelPeripheralConnection:self->_car];  // → 自动重连 → 全新会话
                    });
                } else {
                    SPLog(@"direct", @"★★ 未见 42（换链节流中）—— 交由心跳拍继续尝试");
                }
                return;
            }

            _unlocks++;
            // ★ A1 修复：本链路已解锁，打上记号 —— 否则直发守卫第 437 行恒为假，
            //   车早已解开却每 ~30 秒（SPTick 15s × 20s 冷却）重发一轮四帧。
            //   断开时 didDisconnectPeripheral 会把它清 0，下次靠近照样解锁。
            _doneLink = _linkAt;
            _stallRetries = 0;                         // ★ A1：本轮链路自愈计数归零
            SPLog(@"direct", @"★ 四帧发完（42 已确认）—— 耗时 %.0f ms（累计成功 %ld 次）",
                  (SPNow() - _startAt) * 1000.0, (long)_unlocks);   // ★ C3
            _step = 0;
        }
    } @catch (NSException *e) { SPLog(@"direct", @"onCarFrame 异常: %@", e.reason); _step = 0; }
}

//──────────────────────── CBCentralManagerDelegate ────────────────────────
- (void)centralManagerDidUpdateState:(CBCentralManager *)cm {
    NSString *s = @"未知";
    switch (cm.state) {
        case CBManagerStatePoweredOn:    s = @"已开启";   break;
        case CBManagerStatePoweredOff:   s = @"已关闭";   break;
        case CBManagerStateUnauthorized: s = @"★未授权"; break;
        case CBManagerStateUnsupported:  s = @"不支持";   break;
        case CBManagerStateResetting:    s = @"重置中";   break;
        default: break;
    }
    SPLog(@"boot", @"蓝牙状态 = %ld (%@)", (long)cm.state, s);
    if (cm.state == CBManagerStatePoweredOn) {
        _armed = YES;
        // ★ 1.2.2：蓝牙重新就绪 —— 蓝牙栈重启时系统已作废所有 pending connect，守卫必须复位。
        //   否则上一个连接请求留下的 _connecting=YES 会把此后每一次 tryConnect 永久挡在门外。
        _connecting = NO;
        [self tryConnect];
    } else {
        if (cm.state == CBManagerStateUnauthorized) {
            SPLog(@"boot", @"★ SpringBoard 未获蓝牙授权 —— 无法使用 CoreBluetooth");
        }
        // ★ 1.2.2：非 PoweredOn（关闭 / 重置 / 不可用）⇒ 系统会取消 pending connect，但
        //   **不保证回调** didFailToConnectPeripheral。守卫原先只在这三个回调里清零
        //   （didConnect / didFailToConnect / didDisconnect），一旦不回调用就永久停在 YES，
        //   此后 tryConnect 在第 496 行静默 return —— 用户观感是「关了下蓝牙，再也不连车」。
        //   真机铁证（2026-10-10 22:44:27 下发连接请求后即关蓝牙）：
        //     22:44:27 连接请求 → 蓝牙状态=4 → 22:44:28/45、22:45:00 三次「已开启」全部无声；
        //     22:46:20 / 22:48:22 心跳「外设状态=0」（Disconnected）；
        //     22:45:00 → 22:50:56 共 356 秒（SPTick 约 23 次 tryConnect）「连接请求」0 条；
        //     直到 22:50:56 用户重启用户空间（pid 404）才恢复。
        //   这里主动作废本轮：复位原子守卫 + 清握手状态，保证蓝牙再开时能立刻重新连车。
        if (_connecting || _step != 0) {
            SPLog(@"link", @"蓝牙不可用(%ld) —— 作废本轮连接请求与握手", (long)cm.state);
        }
        _connecting = NO; _stallRetries = 0; _round++; _saw42 = NO;
        _step = 0; _wr = nil; _nt = nil; _doneLink = 0; _linkAt = 0; _lastAt = 0;
    }
}

// 注：SpringBoard 版不再使用状态恢复，这个回调正常情况下不会被调用，保留仅为兼容。
- (void)centralManager:(CBCentralManager *)cm
 willRestoreState:(NSDictionary<NSString *, id> *)dict {
    NSArray<CBPeripheral *> *ps = dict[CBCentralManagerRestoredStatePeripheralsKey];
    SPLog(@"link", @"状态恢复：交还 %lu 个外设", (unsigned long)ps.count);
    for (CBPeripheral *p in ps) [self adopt:p why:@"状态恢复"];
}

- (void)centralManager:(CBCentralManager *)cm
 didDiscoverPeripheral:(CBPeripheral *)p
     advertisementData:(NSDictionary<NSString *, id> *)adv
                  RSSI:(NSNumber *)RSSI {
    @try {
        // ① UUID 命中（App 学到的）
        if (p.identifier.UUIDString && _carUUID.length &&
            [_carUUID caseInsensitiveCompare:p.identifier.UUIDString] == NSOrderedSame) {
            SPLog(@"link", @"★ 车出现 %@ RSSI=%@ — UUID 命中", p.name ?: @"(无名)", RSSI);
            [self stopScan:@"已锁定"]; [self adopt:p why:@"UUID 命中"]; [self tryConnect];
            return;
        }
        // ② 名字前缀命中（车名实测 SDH-xxxxxx）
        NSString *nm = p.name;
        if (nm.length && strlen(kNamePrefix) && [nm hasPrefix:@(kNamePrefix)]) {
            SPLog(@"link", @"★ 车出现 %@ RSSI=%@ — 名字命中", nm, RSSI);
            [self stopScan:@"已锁定"]; [self adopt:p why:@"名字命中"]; [self tryConnect];
            return;
        }
        // ③ 其余只在日志留痕（低频，别刷屏）
        static NSTimeInterval lastLog = 0;
        NSTimeInterval now = SPNow();                  // ★ C3：单调时钟
        if (nm.length && now - lastLog > 20.0) {
            lastLog = now;
            SPLog(@"link", @"旁侧设备 %@ RSSI=%@", nm, RSSI);
        }
    } @catch (NSException *e) { SPLog(@"link", @"didDiscover 异常: %@", e.reason); }
}

- (void)centralManager:(CBCentralManager *)cm didConnectPeripheral:(CBPeripheral *)p {
    _connects++;
    _connecting = NO;    // ★ B2：连接已落地，守卫复位
    _stallRetries = 0;   // ★ A1：新链路，自愈计数归零
    _saw42 = NO;         // ★ 1.2.4：新链路，42 凭证复位
    _backoff = 1.0;      // ★ A3：连上了 → 退避归位 1 秒。
                         //   原来 backoff 是 static 局部变量，只增不减、永不复位，
                         //   封顶 30 秒后即便连成功几十次也永远 30 秒才重连。
                         //   官方 App 的 _backoff 是实例变量并在 7 处主动重置。
    _wr = nil; _nt = nil; _step = 0;
    SPLog(@"link", @"✅ 已连接 %@ (累计 %ld 次)", p.name ?: @"(无名)", (long)_connects);
    p.delegate = self;
    [self stopScan:@"已连接"];
    [p discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)cm
didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    _connecting = NO;                                  // ★ B2
    SPLog(@"link", @"连接失败：%@", e.localizedDescription);
    [self retryLater:@"连接失败"];
}

- (void)centralManager:(CBCentralManager *)cm
didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    _step = 0; _wr = nil; _nt = nil; _doneLink = 0; _linkAt = 0; _saw42 = NO;
    // ★ 1.2.1：冷却锚点也必须随链路作废。1.2.0 在这里清了一堆状态却漏了 _lastAt，
    //   导致「发到一半链路被断 → 立刻重连 → 新链路就绪」时，directBegin 被上一条链路的
    //   20 秒冷却在第 545 行静默 return（零日志），只能等 SPTick 下一拍补发。
    //   真机铁证（2026-10-10 日志）：20:37:31 就绪 → 20:37:59 才发出帧1（+28s，正是用户
    //   「按了两次」的那一回）；21:09:23 就绪 → 21:09:34 才发出（+11s，恰为定时器第 701 拍）。
    //   断开即新一轮，新链路必须能立刻直发。
    _lastAt = 0;                                        // ★ 1.2.1：清冷却，新链路不受上一轮影响
    _connecting = NO; _stallRetries = 0; _round++;      // ★ B2/A1：链路已断，守卫与看门狗全作废
    SPLog(@"link", @"⚠️ 断开：%@", e ? e.localizedDescription : @"主动/正常断开");
    [self retryLater:@"断开"];
}

- (void)retryLater:(NSString *)why {
    // ★ A3：原来这里是 static 局部变量 —— 只增不减、全工程无重置点，封顶后永远 30 秒。
    //   改实例变量 _backoff，并在 didConnectPeripheral 里复位为 1.0。
    NSTimeInterval d = MIN(_backoff, 30.0);
    _backoff = MIN(_backoff * 2.0, 30.0);
    SPLog(@"link", @"%@ → %.0f 秒后重试", why, d);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                   SPQueue(), ^{                                   // ★ B1
        [self tryConnect];
    });
}

//──────────────────────── CBPeripheralDelegate ────────────────────────
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)e {
    for (CBService *s in p.services) {
        SPLog(@"gatt", @"服务 %@", s.UUID.UUIDString);
        [p discoverCharacteristics:nil forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)p
didDiscoverCharacteristicsForService:(CBService *)svc error:(NSError *)e {
    // ★ A2：这两个特征已经拿全了 —— 重复回调不再刷日志、不再重复订阅
    if (_wr && _nt) return;
    for (CBCharacteristic *c in svc.characteristics) {
        if ([c.UUID.UUIDString caseInsensitiveCompare:@"FFF6"] == NSOrderedSame) _wr = c;
        if ([c.UUID.UUIDString caseInsensitiveCompare:@"FFF1"] == NSOrderedSame) _nt = c;
    }
    if (_wr && _nt && !_nt.isNotifying) {
        [p setNotifyValue:YES forCharacteristic:_nt];
        SPLog(@"gatt", @"订阅 FFF1（车的回帧从这条来）");
    }
    if (_wr) {
        _linkAt = SPNow();                             // ★ C3：记号：本链路
        // ★ 1.2.1：原文案「→ 立刻直发」是**提前宣称**——它先喊再调 directBegin，喊完可能
        //   什么都不发（1.2.0 就被冷却吞过 3 次），结果日志口径比实际行为更"乐观"，
        //   上一轮"订阅/就绪/帧1/完成 计数自洽"的审计因此漏判。改为只陈述事实。
        SPLog(@"gatt", @"写特征 FFF6 就绪 —— 请求直发");
        [self directBegin];
    }
}

- (void)peripheral:(CBPeripheral *)p
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)ch error:(NSError *)e {
    // ★ 订阅确认回调：FFF1 订阅成功与否，直接决定车的回帧能不能到我们这里
    if (e) SPLog(@"gatt", @"⚠️ FFF1 订阅失败：%@", e.localizedDescription);
    else   SPLog(@"gatt", @"FFF1 订阅%@（isNotifying=%d）", ch.isNotifying ? @"已生效" : @"被关闭", ch.isNotifying);
}

- (void)peripheral:(CBPeripheral *)p
didUpdateValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)e {
    if (!ch.value || ch.value.length == 0) return;
    SPLog(@"car", @"← 车回帧 %@ len=%lu", ch.UUID.UUIDString, (unsigned long)ch.value.length);
    [self onCarFrame:ch.value];
}

// ★ A2：1.1.6 完全没有实现这个回调。四帧全部用 CBCharacteristicWriteWithResponse 写出，
//   带响应写本该有回执 —— 缺了它，写失败时 _step 既不推进也不回退，直接掉进 A1 要修的
//   停摆，而且要白等一次 8 秒看门狗。
- (void)peripheral:(CBPeripheral *)p
didWriteValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)e {
    if (!ch || [ch.UUID.UUIDString caseInsensitiveCompare:@"FFF6"] != NSOrderedSame) return;
    if (!e) return;                                    // 写成功：不介入，推进交给车回帧
    SPLog(@"direct", @"★ 写 FFF6 失败：%@ —— 释放本轮", e.localizedDescription);
    _step = 0; _lastAt = 0; _round++;                  // 作废本轮看门狗 + 清冷却
}

@end

//════════════════════════════ 常驻驱动 ════════════════════════════
//  P3 保活：每 15 秒核一次 —— 没连就连，连上但没解开就再发一轮。
//  不做任何定时器密集刷（15 秒一次，代价可忽略）。
// ★ 必须静态强持有：CBCentralManager 的 delegate 是 **weak** 引用。
//   1.0.5 日志实测：用块内局部变量时，块一结束实例就被 ARC 回收
//   → delegate 变 nil → centralManagerDidUpdateState 永远不回调
//   （日志只到「SPUnlocker 启动」就断，连一行「蓝牙状态」都没有）
static SPUnlocker *gUnlocker = nil;

static void SPTick(SPUnlocker *u) {
    // ★ 先续期、再干活：否则 armed 还是 NO 时提前 return，循环只跑一次就断
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   SPQueue(), ^{ SPTick(u); });                    // ★ B1
    @try {
        u.ticks++;
        // ★ 心跳：每 8 跳（约 2 分钟）报一次现场，证明插件还活着、外设处于什么状态。
        //   没有它的话，pending connect 若被系统悄悄撤掉，日志上看不出来。
        if (u.armed && (u.ticks % 8) == 0) {
            SPLog(@"life", @"心跳 #%ld 外设状态=%ld 已连=%ld 已解锁=%ld 步=%ld 写特征=%@",
                  (long)u.ticks, (long)u.car.state, (long)u.connects,
                  (long)u.unlocks, (long)u.step, u.wr ? @"有" : @"无");
        }
        if (!u.armed) return;
        if (!u.car || u.car.state != CBPeripheralStateConnected) {
            [u tryConnect];
        } else if (u.wr && u.step == 0) {
            [u directBegin];
        }
    } @catch (NSException *e) { /* 吞 */ }
}

//════════════════════════════ 入口（Theos/logos）════════════════════════════
%ctor {
    @try {
        // ★ C1：先初始化日志，让"安全阀被检查过"变成可验证事实。1.1.6 的 return 发生在
        //   日志初始化之前，开关到底有没有被检查，从日志上完全看不出来。
        SPLogInit();
        NSString *off = SPFind(kKillSwitch);             // ★ 真实根 + rootless + RootHide 隐根
        if (off) { SPLog(@"boot", @"★ kill-switch 命中（%@）—— 不启动蓝牙", off); return; }
        NSString *bid0 = NSBundle.mainBundle.bundleIdentifier ?: @"(无bundle)";
        SPLog(@"boot", @"════ SundiroSPUnlock v%@ 装载 pid=%d uid=%d bundle=%@ ════",
              SPVER, getpid(), getuid(), bid0);
        if (!SPFlag(@"enable", YES)) { SPLog(@"boot", @"配置为停用，退出"); return; }
        dispatch_async(SPQueue(), ^{
            @try {
                gUnlocker = [SPUnlocker new];   // ★ 静态强持有，防被 ARC 回收
                [gUnlocker start];              // ★ D2：SPTick 已移入 start，只有真起了引擎才跑
            } @catch (NSException *e) {
                SPLog(@"boot", @"★ 启动异常 %@: %@\n%@", e.name, e.reason,
                      [e.callStackSymbols componentsJoinedByString:@"\n"]);
            }
        });
    } @catch (NSException *e) { /* 绝不外泄到 SpringBoard */ }
}
