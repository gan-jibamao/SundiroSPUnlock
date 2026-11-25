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
#include <dlfcn.h>
#import <os/log.h>

#define SPVER        @"1.3.13"
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
// ★ 1.2.8：车端固定帧（真机两次按下逐字节相同）
//   按键帧   = 实体开关被按下（空闲期主动推送，26 字节）
//   状态帧   = 我们解锁成功后车补发的状态通知（26 字节，头 7 字节与按键帧完全相同，只有载荷不同）
static const unsigned char kPressFrame[26] = {
    0x55,0x55,0x1A,0x02,0x00,0x01,0x05,0xE1,0xAD,0x87,0x13,0xBF,0x87,0x78,0xF9,0xB7,
    0x01,0xAC,0x4A,0xFE,0xFB,0x04,0x86,0xAA,0xAA,0xAA };
static const unsigned char kStatusFrame[26] = {
    0x55,0x55,0x1A,0x02,0x00,0x01,0x05,0xF7,0xEA,0xB8,0x13,0x52,0xBA,0x60,0x19,0xFF,
    0x82,0xC3,0x77,0x6C,0xAB,0x56,0xD3,0xB0,0xAA,0xAA };

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
// ★ 1.3.13-B：加密/配对失败的连续次数与最近时刻（指数退避用）
//   真机铁证：11-25 07:40:01 「Failed to encrypt」后立即重连，车端退避，
//   直到 07:41:13 才恢复 —— 中间 72 秒链路真空。加密握手是有状态的，
//   连续抢跑只会把车端的退避期拉得更长。
@property (nonatomic, assign) NSInteger         pairFails;    // 连续加密/配对失败次数
@property (nonatomic, assign) NSTimeInterval    pairFailAt;   // 最近一次加密/配对失败时刻
// ★ 1.3.13-C：链路保活
//   真机账（11-23→11-25，23 次连接）：寿命中位 31 秒，其中 7 次只有 1~10 秒；
//   另有 688 / 611 / 537 / 510 秒的长命链路 —— 说明车本身是肯长连的，
//   短命那批更可能是「链路上没有任何流量，车端判定空闲后清扫」。
//   连上后我们只被动等按键帧，GATT 层一分钟不发一个字节。
//   每 20 秒打一次 ATT 往返，让链路保持活跃，减少「按下去时链路已经没了」。
@property (nonatomic, assign) NSTimeInterval    kaAt;         // 上次保活时刻
@property (nonatomic, assign) NSTimeInterval    kaLogAt;      // 保活日志限流
@property (nonatomic, assign) NSInteger         kaCount;      // 保活计数
@property (nonatomic, assign) BOOL              connecting;   // ★ B2：连接请求已下发（原子守卫）
@property (nonatomic, assign) NSTimeInterval    connAt;       // ★ 1.2.2：连接请求下发时刻（守卫卡死判定用）
@property (nonatomic, assign) NSTimeInterval    guardLogAt;   // ★ 1.2.2：守卫早退日志限流
@property (nonatomic, assign) NSUInteger        round;        // ★ A1：解锁轮次号（看门狗代际校验）
@property (nonatomic, assign) NSInteger         stallRetries; // ★ A1：本链路自愈重发次数
@property (nonatomic, assign) BOOL              saw42;        // ★ 1.2.4：本轮是否见过 42 帧（车端受理凭证）
@property (nonatomic, assign) NSTimeInterval    no42At;       // ★ 1.2.4：上次因未见42主动换链时刻（60秒节流）
@property (nonatomic, assign) NSTimeInterval    doneAt;       // ★ 1.2.6：本链路完成时刻（时效窗锚点）
@property (nonatomic, assign) NSInteger         redoOnLink;   // ★ 1.2.6：本链路补发轮数（上限 2）
@property (nonatomic, assign) NSTimeInterval    dirLogAt;     // ★ 1.2.6：directBegin 早退日志限流
@property (nonatomic, assign) BOOL              fullDiscovery;// ★ 1.2.6：是否已退回全量 GATT 发现
@property (nonatomic, assign) BOOL              fullOnce;      // ★ 1.2.11：本条链路一次性全量（不改拓扑结论）
                                                            //   1.2.10 真机铁证：10:34:54 因 FFF0 回包慢（5.0 秒）
                                                            //   触发 3.5 秒兜底，却写死了 _fullDiscovery ⇒ 之后
                                                            //   10:35:05 那条链路直接全量发现 6 个服务，
                                                            //   「连接→写特征就绪」由 1 秒涨到 5 秒，且永久生效。
@property (nonatomic, assign) BOOL              carFromApp;    // ★ 1.2.14：车 UUID 来自官方 App plist（权威，不许被名字匹配覆盖）
@property (nonatomic, assign) NSInteger          lastRSSI;      // ★ 1.2.15：最近一次看到车的信号强度
@property (nonatomic, assign) NSTimeInterval     lastSeenAt;    // ★ 1.2.15：最近一次看到车的时刻
@property (nonatomic, assign) NSTimeInterval     lastConnAt;    // ★ 1.2.15：最近一次真正连上的时刻（弱信号兜底用）
@property (nonatomic, assign) NSTimeInterval     rssiLogAt;     // ★ 1.2.15：RSSI 日志限流
@property (nonatomic, assign) NSInteger          rssiPrev;      // ★ 1.3.1：上一次 RSSI（判趋势用）
@property (nonatomic, assign) NSInteger          risingCount;   // ★ 1.3.1：RSSI 连续变强的次数
@property (nonatomic, assign) NSTimeInterval     trendConnAt;   // ★ 1.3.1：趋势预连节流
@property (nonatomic, assign) BOOL              pressQueued;   // ★ 1.2.13：握手期收到按键帧，本轮结束后补发
@property (nonatomic, assign) NSTimeInterval    connReqAt;     // ★ 1.3.0：最近一次下发连接请求的时刻（forceReconnect 节流）
@property (nonatomic, assign) BOOL              linkReady;     // ★ 1.3.0：本链路 GATT 已就绪过（didConnect 里取快照用，_wr 清零会丢）
@property (nonatomic, assign) BOOL              unlockOnReady; // ★ 1.3.0：本链路 GATT 就绪后是否自动解一轮（睡醒才 YES）
@property (nonatomic, assign) NSTimeInterval    lastOkAt;      // ★ 1.2.12：上次成功解锁时刻
                                                            //   连上就解冷却门禁的锚点（600 秒）。
                                                            //   1.2.11 真机：34.8 分钟 8 次自发解锁，
                                                            //   其中 15:43:14 车发状态帧（疑似锁车）后
                                                            //   2 分钟 15:45:31 我们无按键把车解开了。
@property (nonatomic, assign) BOOL              fff0CharsDone; // ★ 1.2.6：本链路 FFF0 的特征是否已回
@property (nonatomic, assign) NSTimeInterval    lastCarAt;     // ★ 1.2.7：上一条车帧时刻（判按键间隔）
@property (nonatomic, assign) BOOL              forceSend;     // ★ 1.2.7：按键触发，绕过完成门禁与冷却
@property (nonatomic, assign) BOOL              carSendsPress;   // ★ 1.2.10：本车会主动发按键帧（跨链路记忆，重连不重置）
@property (nonatomic, assign) BOOL              stuckCancel;    // ★ 1.2.9：主动取消卡死连接（防重复排程重连）
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
    // ★ 1.2.14：断链期间**持续扫描**，不再「25 秒窗口 + 60 秒冷却」。
    // ★ 1.2.15：AllowDuplicates 必须为 YES —— 原来为 NO，iOS 在每个扫描会话里
    //   对每台设备**只回调一次**，RSSI 永远拿不到更新（1.2.14 真机 95 分钟「车出现」
    //   只有 3 次，正是这个原因）。没有连续 RSSI 就无法做靠近判定。
    NSDictionary *o = @{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES };
    [_cm scanForPeripheralsWithServices:nil options:o];
    _scanning = YES;
    SPLog(@"link", @"开始扫描（全设备、含重复回调，%@）", why);
}

- (void)stopScan:(NSString *)why {
    if (!_scanning) return;
    _scanning = NO;
    [_cm stopScan];
    SPLog(@"link", @"停止扫描（%@）", why);
}

// ★ 1.2.13：连接选项。iOS 17+ 带「允许系统自动重连」，让 bluetoothd 替我们守着回连；
//   官方 App 同样做法（SundiroBLE.m:583-586）。iOS 16 上不传，避免未知 key 引发异常。
static NSDictionary *SPConnectOptions(void) {
    // ★ 1.3.10-CI：改用「运行期 API 存在性探测」代替 @available。
    //   原因：@available 会引用编译期符号 ___isPlatformVersionAtLeast，
    //   该符号由 libclang_rt.iossim/系统库提供；在 Linux 上用 theos 的
    //   iOSToolchain 交叉编译时链接不到它，arm64 与 arm64e 双架构全部报
    //   `Undefined symbols: ___isPlatformVersionAtLeast`，
    //   构建在 Linking 阶段失败（2026-11-08 CI #63 实测）。
    //   改用 dlsym 探测 CoreBluetooth 里该常量的符号是否存在：
    //   · iOS 17+ 有该常量 ⇒ 返回字典，语义与原来完全一致
    //   · iOS 16 及以下没有 ⇒ 返回 nil，与原 @available 分支一致
    //   注意：只在首次调用时探测一次，结果缓存，不落在解锁关键路径上。
    static BOOL probed = NO;
    static BOOL supported = NO;
    if (!probed) {
        probed = YES;
        // kCBConnectOptionEnableAutoReconnect 是 CoreBluetooth 导出的 NSString * 常量
        void *sym = dlsym(RTLD_DEFAULT, "kCBConnectOptionEnableAutoReconnect");
        supported = (sym != NULL);
    }
    if (supported) return @{ @"kCBConnectOptionEnableAutoReconnect": @YES };
    return nil;
}

// ★ 1.2.13：扫描扫到车时，强制重新下发连接请求。
//   原因：pending connect 可能已静默失效，而 _connecting 守卫仍是 YES、外设状态仍报
//   Connecting(1)，于是 tryConnect 会在 `if (_connecting)` 与 `if (state==Connecting)`
//   两道守卫上直接早退 —— 扫到了也连不上。真机 1.2.12 实测 pending 空转 31 分 46 秒，
//   心跳全程「外设状态=1 写特征=无」，正是这种「系统说在连、其实没在连」的状态。
//   注意：不修改 _connAt —— 它记录的是「最早那次请求」，用来判定车睡了多久。
- (void)forceReconnect:(NSString *)why {
    if (!_cm || _cm.state != CBManagerStatePoweredOn) return;
    if (!_car || _car.state == CBPeripheralStateConnected) return;
    // ★ 1.3.3（A）：车在广播 = 车醒着 = 这是最能连上的窗口，必须抢抓。
    //   1.3.2 真机铁证：21:26:29 断开后，pending connect 挂了 26 分钟（21:47:21
    //   已挂 1252 秒）都连不上，用户这期间按车钥匙按了很多下全部落空（零日志）。
    //   而 21:53:05 车一广播（RSSI 突然 -46），1 秒内就连上，21:53:14 按键 1319 ms 完成。
    //   也就是说：瓶颈不是「连不上」，是「车醒着的那几十秒里我们没把连接推上去」。
    //   原来的 3 秒节流在弱信号下等于白白放走唤醒窗口 —— 车广播往往只持续很短时间。
    //   改为：车在广播时（本函数只会由 didDiscoverPeripheral 命中后调用）
    //   节流到 0.5 秒；其余路径不变。
    NSTimeInterval fnow = SPNow();
    if (_connReqAt > 0 && fnow - _connReqAt < 0.5) return;
    _connReqAt = fnow;
    // ★ 1.3.5：修 1.3.3 引入的死循环。1.3.3 在这里**无条件** cancelPeripheralConnection，
    //   而车在广播时每秒会回调多次 ⇒ 每秒 cancel 一次 ⇒ 连接永远建立不起来。
    //   真机铁证（10-28 19:35:51 起）：13 分钟里 188 次断开 / 184 次强制重发 /
    //   只有 6 次连上，且「车主动发帧」= 0 —— 用户按键一次都没被识别，
    //   因为链路从未真正建立过。
    //   现在：只有「挂起超过 90 秒且状态仍是 Connecting」才认定为真僵尸，才 cancel；
    //   其余情况只调 connectPeripheral（对已挂起的请求是幂等的，系统会忽略重复下发）。
    NSTimeInterval held = (_connAt > 0) ? (fnow - _connAt) : 0;
    // ★ 1.3.13-A1：不再主动取消 pending connect（原逻辑：state==Connecting 且 held>90 秒即 cancel 重发）。
    //
    //   真机铁证（11-23 23:02 → 11-25 10:13，35.2 小时 / 3409 行日志）：
    //     · ★ 僵尸 pending 54 次，⚠️ 主动/正常断开 55 次 —— 一一对应，全部是我方 cancel；
    //     · 每次 cancel 都把 iOS 已经替我们持有的 pending connect 扔掉，重新排队；
    //     · 11-25 07:39:35 断开 → 07:40:01 Failed to encrypt → 07:41:13 才连上，
    //       中间 98 秒链路真空；用户在车旁按的每一次全部落空（车不重发按键帧）；
    //     · 同一时段 07:39:04（下发请求后 1.7 秒连上）、07:41:13（车一广播即连上）
    //       证明 pending connect 本身是好的 —— 瓶颈不是「连不上」，是「我们把队列扔了」。
    //     · 35.2 小时里每一次车真的发帧都成功解锁（10 次解锁 / 7 次按键突发），
    //       解锁逻辑无问题，丢的全是「链路没备好时的那一按」。
    //
    //   connectPeripheral 对已挂起的请求是幂等的（v1.3.5 注释已确认），重复下发无副作用。
    //   真正「请求被系统丢弃」的情形由 tryConnect 的 `state == Disconnected` 分支处理
    //   （那里本来就不 cancel，只重置守卫后重发）。
    if (_car.state == CBPeripheralStateConnecting && held > 90.0) {
        if (fnow - _guardLogAt > 600.0) {      // 只记日志，不动连接。10 分钟一条。
            _guardLogAt = fnow;
            SPLog(@"link", @"pending 已挂 %.0f 秒（状态=1）—— 保持不动，等车广播（%@）",
                  held, why);
        }
    }
    SPLog(@"link", @"扫描命中 → 重发连接请求（%@，外设状态=%ld，已挂 %.0f 秒）",
          why, (long)_car.state, held);
    _connecting = YES;
    if (!_connAt) _connAt = fnow;               // 守卫哨兵锚点；不改写早先的请求时刻
    [_cm connectPeripheral:_car options:SPConnectOptions()];
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
    // ★ 1.2.13：车已认到、但没连上时**也必须扫描**。
    //   原来 beginScan 全工程只有上面 `if (!_car)` 一个调用点，车一认到（retrieve 命中）
    //   就永久停扫 ⇒ 整份 1.2.12 真机日志 259 KB 里「开始扫描」**0 条**，
    //   我们 100% 依赖 iOS 的 pending connect。
    //   实测它会静默失效：18:37:37 断开后 pending 挂了 31 分 46 秒（心跳 外设状态=1
    //   全程为 1，即 iOS 自认为还在连），期间完全失明，用户 19:08 按的每一次都没有
    //   链路可承载。官方 App 三保险（startScan + EnableAutoReconnect + 30 秒 watchdog）
    //   我们一道都没有，见 /var/minis/shared/SundiroBLE/sble/SundiroBLE.m:586/698。
    //   扫描本身也带诊断价值：扫得到车 ⇒ pending 失效（可修）；扫不到 ⇒ 车端不广播。
    if (_car.state != CBPeripheralStateConnected) [self beginScan:@"等待车广播"];
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
        // ★ 1.2.10：撤销 1.2.9 的「挂起 8 秒就取消」—— 那是误诊。
        //   1.2.9 真机 6h45m 实测：取消 1684 次，**全部** 外设状态=1（Connecting）。
        //   状态=1 = iOS 仍持有 pending connect，车一广播就自动连上 —— 最省电也最快。
        //   1.2.8 那 63 秒不是 bug，是车在睡觉，pending connect 一直在等，车醒就自己连上了。
        //   每 8 秒取消重发 = 把「安静等车出现」换成「每 9 秒重排一次队」：
        //     ① 6h45m 内 1684 次无谓重连（≈250 次/小时），耗电；
        //     ② [link] 日志占 91%，524 KB/6.75h，轮转极快会挤掉真证据；
        //     ③ 每次取消后有 1 秒空窗，车的广播窗口落进去就要多等一轮。
        //   上面 1.2.3 的注释早就写明「状态=1 健康」，1.2.9 自相矛盾。
        if (_car.state == CBPeripheralStateDisconnected) {
            // 真异常：iOS 把我们的请求丢了（蓝牙重启 / 系统回收），守卫却还挂着 → 立刻重发
            if (gnow - _guardLogAt > 60.0) {
                _guardLogAt = gnow;
                SPLog(@"link", @"连接请求已丢失（状态=0 但守卫挂 %.0f 秒）—— 重发", held);
            }
            _connecting = NO;
            _connAt = 0;
            _backoff = 1.0;
            [self tryConnect];
            return;
        }
        // ★ 1.3.13-A2：阈值 180 → 900 秒，车可见窗口 120 → 60 秒。
        //   原来的 180 秒 + 车可见 120 秒，在真机上仍然太松：11-23→11-25 日志里
        //   僵尸 pending 的 held 值全部落在 90~131 秒，说明「车刚广播过一次（哪怕 RSSI -94）
        //   然后睡着」就会满足 sinceSeen<=120 从而触发 cancel —— 而这正是最常见的形态。
        //   改为「车此刻正在广播（60 秒内扫到）+ 我们已经挂了 15 分钟」才认定真死，
        //   把 cancel 从 54 次/35.2h 压到接近 0。cancel 之后仍保留重扫与重连。
        if (held > 900.0 && _car.state != CBPeripheralStateConnected) {
            // ★ 1.3.10-D 修复（条件化）：原条件是 `_car.state != CBPeripheralStateConnecting`。
            //   但挂起时 state 恒为 Connecting(1)，`!= Connecting` 永远为假 ⇒
            //   这条 3 分钟兜底一次都没执行过。
            //   1.3.9 真机铁证（三天日志）：240 条「已挂 > 600 秒」，
            //   最长 21542 秒（5.98 小时）；11-06 04:03 挂 9.29 小时、
            //   11-08 04:03 挂 2.11 小时，全部显示「外设状态=1」，
            //   而「★ 连接卡死」日志出现 0 次 —— 条件从未成立。
            //
            //   ★ 但不能无条件每 3 分钟取消一次 —— 那会把「车睡着时安静等待」
            //     变成「每 3 分钟折腾一次」，白耗电，还可能丢掉车醒的瞬间。
            //     真机佐证：11-06 18:45→04:03 与 11-08 01:56→07:13 两段长挂起里，
            //     车 SDH-49D6FD **一次广播都没出现**（3 处命中全是 plist 里的固定车名，
            //     不是扫描命中）。也就是说 cancel+reconnect 在这两段里毫无意义。
            //
            //   条件化判据（1.3.13-A2 收紧）：只有「车此刻正在广播（≤60 秒前扫到过）」
            //   且已挂 15 分钟（见上面的 held > 900）才判定卡死。
            //     · 车此刻在广播却仍连不上 ⇒ 真卡死，必须 cancel 重来
            //     · 车不可见（睡着） ⇒ 保持 pending 安静等待，绝不折腾
            NSTimeInterval sinceSeen = (_lastSeenAt > 0) ? (gnow - _lastSeenAt) : 1e9;
            if (sinceSeen <= 60.0) {
                SPLog(@"link", @"★ 连接卡死 %.0f 秒（状态=%ld，车可见 %.0f 秒前）—— 取消重来",
                      held, (long)_car.state, sinceSeen);
                _connecting = NO;
                _connAt = 0;
                _backoff = 1.0;
                _stuckCancel = YES;                 // 断线回调里不再重复排程
                [_cm cancelPeripheralConnection:_car];
                // ★ 附带：取消后必须重扫，否则 A5 无从触发（同 C 阶段）。
                [self stopScan:@"卡死取消后复位扫描标志"];
                [self beginScan:@"卡死取消后重扫"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               SPQueue(), ^{ [self tryConnect]; });
                return;
            }
            // 车不可见：不取消，只在日志里点明「在等车醒」，10 分钟一条别刷屏
            if (gnow - _guardLogAt > 600.0) {
                _guardLogAt = gnow;
                // ★ 1.3.11：_lastSeenAt==0 时 sinceSeen 是 1e9 哨兵，只服务上面「<=120」的判据，
                //   不能原样拼进日志 —— 1.3.10 真机刷过 93 条「车已 1000000000 秒不可见」。
                NSString *seenText = (_lastSeenAt > 0)
                    ? [NSString stringWithFormat:@"车已 %.0f 秒不可见", sinceSeen]
                    : @"本次会话从未见过车";
                SPLog(@"link", @"连接挂起 %.0f 秒（状态=%ld）—— %@，继续等车广播",
                      held, (long)_car.state, seenText);
            }
            return;
        }
        if (gnow - _guardLogAt > 600.0) {       // 健康挂起（状态=1）：10 分钟一条，中性措辞
            _guardLogAt = gnow;
            // ★ 1.3.13-A2：阈值抬到 900 秒后，「车已 N 秒不可见」这条会很少走到，
            //   把可见性信息并进健康挂起日志，保留诊断价值。
            NSTimeInterval ss = (_lastSeenAt > 0) ? (gnow - _lastSeenAt) : -1.0;
            NSString *seenText = (ss >= 0)
                ? [NSString stringWithFormat:@"车已 %.0f 秒不可见", ss]
                : @"本次会话从未见过车";
            SPLog(@"link", @"连接请求仍在挂起（已挂 %.0f 秒，外设状态=%ld）—— %@",
                  held, (long)_car.state, seenText);
        }
        return;
    }
    if (_car.state == CBPeripheralStateConnected || _car.state == CBPeripheralStateConnecting) return;
    // ★ 1.3.0：撤销 1.2.15 的 RSSI 连接门禁 —— 连接提前备好是「按键秒解锁」的前提。
    //   1.2.15 把「连接」和「解锁」绑在一起设门禁：RSSI ≥ -80 才连。但按键帧要靠
    //   已建立的链路承载 —— 走近到 -80 才开始连，连上还要 1~3 秒 GATT 就绪，
    //   正好撞上用户按第一下的窗口，反而变慢。
    //   现在拆开：连接恢复 pending connect 常挂（iOS 持有，零扫描零耗电，车一广播
    //   即连，链路提前备好）；「要不要解锁」由 directBegin 侧负责（按键帧触发 /
    //   睡醒补一次），人在远处不按键就不会发帧，1.2.15 想防的「远处自动解锁」
    //   同样不会发上。RSSI 只留作日志参考（_lastRSSI/_lastSeenAt 仍在 didDiscover 更新）。
    _connecting = YES;
    _connAt = SPNow();                                        // ★ 1.2.2：记下发时刻
    _connReqAt = _connAt;                                     // ★ 1.3.0：节流锚点
    SPLog(@"link", @"连接请求 -> %@", _carName ?: _carUUID ?: @"(未知)");
    [_cm connectPeripheral:_car options:SPConnectOptions()];   // ★ 1.2.13：iOS 17+ 带系统自动重连
    // ★ 1.2.10：删除 1.2.9 的「独立 8 秒超时检查」—— 不再需要。
    //   撤销后 pending connect 一直挂着，车广播即连；SPTick 每 15 秒一拍足够处理真卡死。
    NSUInteger gen = _round;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   SPQueue(), ^{
        if (self->_round != gen) return;        // 链路代际已变，忽略
        if (!self->_connecting) return;         // 已连上 / 已被处理
        [self tryConnect];
    });
}

- (void)adopt:(CBPeripheral *)p why:(NSString *)why {
    if (!p.identifier) return;
    NSString *newUUID = p.identifier.UUIDString;
    // ★ 1.2.14：UUID 来自官方 App 的 plist（retrieve 命中），是**权威值**。
    //   1.2.13 常驻扫描后，「SDH-」名字前缀把 _car 抢到了另一台 SDH-4B834A 上
    //   （真机 19:39:25），4 帧全部发给了别人的车。除非来源是权威渠道
    //   （retrieve / 状态恢复 / UUID 命中），否则不许把已知的 App UUID 换掉。
    if ([why isEqualToString:@"名字命中"] && _carFromApp && _carUUID.length &&
        newUUID.length && ![_carUUID isEqualToString:newUUID]) {
        SPLog(@"link", @"★ 拒绝换车：%@ 名字像但不是同一台（保留 App 权威 UUID）", p.name ?: @"(无名)");
        return;
    }
    // ★ 1.2.10：只有「换车」才清「本车会发按键帧」的记忆；同一台车反复 adopt 不能清
    if (_carUUID.length && newUUID.length && ![_carUUID isEqualToString:newUUID]) {
        _carSendsPress = NO;
        SPLog(@"link", @"换车 %@ → %@ —— 重置按键帧记忆", _carUUID, newUUID);
    }
    _car = p;
    _carUUID = newUUID;
    if (p.name.length) _carName = p.name;
    if ([why isEqualToString:@"retrieve"]) _carFromApp = YES;   // ★ 1.2.14：UUID 来自 App plist
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
        NSTimeInterval t0 = SPNow();                   // ★ 1.2.6：早退日志用（此时 now 尚未声明）
        if (!SPFlag(@"unlock", YES)) return;
        if (_step != 0) {
            if (t0 - _dirLogAt > 5.0) {
                _dirLogAt = t0;
                SPLog(@"direct", @"直发被「本轮进行中」挡住（step=%ld）", (long)_step);
            }
            return;
        }
        if (!_wr || _car.state != CBPeripheralStateConnected) {
            if (t0 - _dirLogAt > 5.0) {
                _dirLogAt = t0;
                SPLog(@"direct", @"直发被「链路未就绪」挡住（写特征=%@ 状态=%ld）",
                      _wr ? @"有" : @"无", (long)_car.state);
            }
            return;
        }
        NSTimeInterval now = SPNow();                  // ★ C3：单调时钟
        // 同一条链路已完整发过一轮 → 不再无条件重发（车早就解开了）。
        // ★ 1.2.6：原实现是「本链路永久封死」，实测封死中位 126 秒、最长 20.7 分钟，
        //   78% 的轮次封死超过 30 秒 —— 这期间用户按实体开关，插件零动作零日志。
        // ★ 1.2.7：改为「按键帧触发」—— 空闲期车主动发帧才发，定时器仅留 90 秒兜底 1 次。
        // ★ 1.2.7：本链路已完成后 —— 只认「车主动发帧（实体开关）」触发；
        //   定时器不再补发（1.2.6 实测 30 秒内自发 2 轮，纯属白烧）。
        // ★ 1.2.8：链路现在能活 10+ 分钟（实测 07:42:19→07:52:16），原来「每链路只兜底 1 次」
        //   一用掉就永久哑火。改为每 90 秒可兜底 1 次、每条链路最多 3 次，收到任何车帧即复位。
        if (_doneLink > 0 && _linkAt > 0 && fabs(_doneLink - _linkAt) < 0.001 && !_forceSend) {
            NSTimeInterval age = (_doneAt > 0) ? (now - _doneAt) : 1e9;
            // ★ 1.2.9：本链路一旦见过按键帧（字节直认），说明该车会主动推送按键信号，
            //   定时兜底就只剩「没人按也解锁」这一个副作用 —— 永久关闭。
            //   真机铁证（1.2.8，08:03→08:16）：13 分钟 10 轮解锁，其中 4 轮用户明确没按。
            if (age < 90.0 || _redoOnLink >= 3 || _carSendsPress) {
                if (now - _dirLogAt > 300.0) {     // ★ 1.2.11：60 秒 → 300 秒
                                                   //   1.2.10 真机实测 10:37:27→10:52:37 空闲 15 分钟刷了 17 条，
                                                   //   占本段 [direct] 日志 27%，会加速 512 KB 轮转挤掉真证据。
                    _dirLogAt = now;
                    SPLog(@"direct", @"直发被「本链路已完成」挡住（完成于 %.0f 秒前，等车帧触发，兜底 %ld/3）",
                          age, (long)_redoOnLink);
                }
                return;
            }
            _redoOnLink++;
            _doneAt = now;                          // 重置 90 秒窗口，下次兜底再等 90 秒
            SPLog(@"direct", @"★ 90 秒无车帧 —— 兜底补发（第 %ld/3 次）", (long)_redoOnLink);
        }
        // 冷却 20 秒：只作**同链路**防抖兜底。链路一断 _lastAt 即归零（见 didDisconnectPeripheral），
        // 所以新链路永远不会被上一轮的冷却挡住。本条排在 _doneLink 守卫之后，不会在
        // 「本轮已发完」的 15 秒轮询里刷屏。
        // ★ 1.2.1：这个分支原来零日志 —— 正是它把「按一次不开、要按两次」藏了整整一个版本。
        if (!_forceSend && _lastAt > 0 && now - _lastAt < 20.0) {
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
        // ★ 1.2.8：握手期屏蔽非握手帧 —— 按键帧/状态帧与 step-1 回复同为 26 字节，
        //   且头 7 字节完全相同（只有第 8 字节 01 vs 05 不同）。握手途中按开关会被当成
        //   step-1 回复吞掉 → 串帧 → 本轮报废。这里只屏蔽两条**已知固定帧**，其余帧型行为不变。
        if (L == 26) {
            const uint8_t *hb = (const uint8_t *)d.bytes;
            if (memcmp(hb, kPressFrame, 26) == 0 || memcmp(hb, kStatusFrame, 26) == 0) {
                // ★ 1.2.13：握手期收到**按键帧**不能再白丢 —— 记下来，本轮结束立刻补一轮。
                //   1.2.12 真机铁证：19:09:24 插件自发开轮，19:09:27 用户按键帧到达被丢弃，
                //   随后该轮 8 秒无回复触发自愈重发，19:09:34 才完成 —— 用户按下去到解开
                //   共 7 秒，而如果没被丢，那一下本来 1.5 秒就能完成。
                //   上限 1 次，避免连续按键把轮次拖成风暴。
                BOOL isPressNow = (memcmp(hb, kPressFrame, 26) == 0);
                if (isPressNow && !_pressQueued) {
                    _pressQueued = YES;
                    SPLog(@"direct", @"★ 握手期收到按键帧 —— 已排队，本轮结束后补发（step=%ld）", (long)_step);
                } else {
                    SPLog(@"direct", @"握手进行中收到按键/状态帧 —— 忽略（step=%ld）", (long)_step);
                }
                return;
            }
        }
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
            _doneAt   = SPNow();                       // ★ 1.2.6：时效窗起点
            _lastOkAt = SPNow();                       // ★ 1.2.12：连上就解冷却锚点（任何来源的成功解锁都算）
            _stallRetries = 0;                         // ★ A1：本轮链路自愈计数归零
            SPLog(@"direct", @"★ 四帧发完（42 已确认）—— 耗时 %.0f ms（累计成功 %ld 次）",
                  (SPNow() - _startAt) * 1000.0, (long)_unlocks);   // ★ C3
            _step = 0;
            // ★ 1.2.13：握手期被挡下的按键，本轮结束后立即补一轮（按键不白按）
            if (_pressQueued) {
                _pressQueued = NO;
                SPLog(@"direct", @"★ 补发握手期排队的那一下");
                _forceSend = YES;
                [self directBegin];
                _forceSend = NO;
            }
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
        _doneAt = 0; _redoOnLink = 0; _fullDiscovery = NO; _fff0CharsDone = NO;   // ★ 1.2.6：时效窗与发现模式一并复位
        _carSendsPress = NO;    // ★ 1.2.10：蓝牙重开 → 重新观察本车是否发按键帧
        _connAt = 0; _connReqAt = 0; _linkReady = NO; _unlockOnReady = NO;   // ★ 1.3.0
        _lastRSSI = 0; _lastSeenAt = 0;   // ★ 1.3.0：旧信号痕迹不带到新蓝牙会话
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
        if (p.state == CBPeripheralStateConnected) return;
        BOOL isMine = (p.identifier.UUIDString && _carUUID.length &&
                       [_carUUID caseInsensitiveCompare:p.identifier.UUIDString] == NSOrderedSame);
        // ★ 1.3.5：状态=Connecting 时不再反复触发连接下发。
        //   1.3.3 真机（10-28 19:35:51 起 13 分钟）：车在广播时每秒回调多次，
        //   每次都走 forceReconnect，配合无条件的 cancel ⇒ 188 次断开 / 184 次重发 /
        //   仅 6 次连上，「车主动发帧」= 0（用户按键完全没被识别）。
        //   正常挂起交给 forceReconnect 内部的「僵尸判定（>90 秒）」处理，
        //   这里只负责把 RSSI 记下来，不再驱动连接。
        if (p.state == CBPeripheralStateConnecting) {
            NSInteger rr = RSSI.integerValue;
            if (rr < 0 && rr > -127) {
                _lastRSSI   = rr;
                _lastSeenAt = SPNow();
            }
            // 唯一例外：真僵尸（挂起 >90 秒）—— 必须在这里主动调一次，
            // 否则 forceReconnect 永远不会被触发，僵尸状态无法解除。
            NSTimeInterval heldNow = (_connAt > 0) ? (SPNow() - _connAt) : 0;
            if (heldNow > 90.0) {
                [self forceReconnect:(isMine ? @"UUID 命中(僵尸)" : @"名字命中(僵尸)")];
            }
            return;
        }
        // ★ A5 修复：状态=Disconnected 且看到车在广播 ⇒ 立刻重连，不等 SPTick 的 15 秒。
        //   用户的解锁流程是「靠近 → 按车键 → 车只在那一刻推一帧」，
        //   车不会重发；链路若正好断在这 15 秒空窗里，那一帧就永久丢失，
        //   表现出来就是「按了没反应」。
        //   现在：车醒着（在广播）就直接把连接推上去，1 秒节流防风暴。
        if (isMine && p.state == CBPeripheralStateDisconnected) {
            NSTimeInterval seenNow = SPNow();
            if (seenNow - _connReqAt > 1.0) {
                SPLog(@"link", @"★ 车在广播但链路断开 —— 立即重连（A5）");
                _connReqAt = seenNow;
                _connecting = YES;
                _connAt = seenNow;       // 新请求，重新计时（避免被误判成 90 秒僵尸）
                [_cm connectPeripheral:p options:SPConnectOptions()];
            }
        }
        // ② 名字前缀命中（车名实测 SDH-xxxxxx）
        // ★ 1.2.14：已知车名后必须**完全同名**才认。
        //   「SDH-」只是品牌前缀，不是唯一标识 —— 现场同时有两台 SDH- 车
        //   （SDH-49D6FD / SDH-4B834A）。1.2.13 把扫描改成常驻后立刻爆雷：
        //   真机 19:39:25 UUID 命中你的车，同一秒名字命中了 SDH-4B834A，
        //   _car 被抢走并重置按键帧记忆，随后 4 帧全发给了别人的车。
        NSString *nm = p.name;
        if (!isMine) {
            BOOL nameMatch = (nm.length && strlen(kNamePrefix) && [nm hasPrefix:@(kNamePrefix)]
                              && (!_carName.length || [nm isEqualToString:_carName]));
            if (!nameMatch) {
                // ③ 其余只在日志留痕（低频，别刷屏）
                static NSTimeInterval lastLog = 0;
                NSTimeInterval now0 = SPNow();
                if (nm.length && now0 - lastLog > 20.0) {
                    lastLog = now0;
                    SPLog(@"link", @"旁侧设备 %@ RSSI=%@", nm, RSSI);
                }
                return;
            }
        }
        // ★ 1.3.0：识别与日志保留，但 RSSI 不再作为连接门禁（连接提前备好，
        //   按键才有链路可承载）。1.2.15 曾在这里按 RSSI ≥ -80 拦截，已撤销。
        NSTimeInterval now = SPNow();
        // ★ 1.3.4：RSSI 无效值过滤。CoreBluetooth 用 127 表示「本次广播没有有效 RSSI」，
        //   1.3.3 真机 10-28 11:23:34 出现过 `RSSI=127`，会让趋势判定误判「信号暴涨」。
        //   负值才是真实信号；0 与正数一律丢弃，只用上一次的有效值。
        NSInteger r = RSSI.integerValue;
        BOOL rssiValid = (r < 0 && r > -127);
        // ★ 1.3.1（B）：RSSI 趋势预连。
        //   1.3.0 真机 360 分钟实证：链路可用率仅 5.9%，而两次命中按键
        //   （10:36:13 / 11:03:37）都是「刚好落在链路活着的窗口」。也就是说——
        //   按键能不能秒解，取决于按下的那一刻链路是否还活着。
        //   遥测显示车在 30 米内 RSSI 中位 -94（穿墙），连接本身就在临界点上。
        //   这里加一层：当 RSSI 连续 3 次变强（人正在走近），提前发起连接，
        //   争取让用户走到车旁时链路已经备好，按第一下就能中。
        //   节流 60 秒，避免同一波接近重复下发。
        // ★ 1.3.4：无效 RSSI 直接跳过趋势计算（1.3.3 真机见过 RSSI=127 的哨兵值）
        if (!rssiValid) {
            if (now - _rssiLogAt > 30.0) {
                _rssiLogAt = now;
                SPLog(@"link", @"★ 车出现 %@（RSSI 无效=%@，忽略）— %@",
                      nm ?: @"(无名)", RSSI, isMine ? @"UUID 命中" : @"名字命中");
            }
            [self adopt:p why:(isMine ? @"UUID 命中" : @"名字命中")];
            [self forceReconnect:(isMine ? @"UUID 命中" : @"名字命中")];
            return;
        }
        if (_lastRSSI != 0 && r > _lastRSSI + 2) {
            _risingCount++;
        } else if (r <= _lastRSSI) {
            _risingCount = 0;
        }
        _rssiPrev   = _lastRSSI;
        _lastRSSI   = r;
        _lastSeenAt = now;
        BOOL trending = (_risingCount >= 3 && (now - _trendConnAt > 60.0));
        if (trending) _trendConnAt = now;
        // ★ 1.3.4：原来是 %s + C 字符串，中文经 NSString 系统编码（MacRoman）解释后
        //   变成乱码（1.3.3 真机表现为 `RSSI=-96¿÷à˜ c`）。改用 %@ + NSString 字面量。
        SPLog(@"link", @"★ 车出现 %@ RSSI=%ld%@ — %@",
              nm ?: @"(无名)", (long)r,
              trending ? @"（连续变强，预连）" : @"",
              isMine ? @"UUID 命中" : @"名字命中");
        [self adopt:p why:(isMine ? @"UUID 命中" : @"名字命中")];
        if (trending) {
            SPLog(@"link", @"★ RSSI 连续 %ld 次变强（%ld → %ld）—— 提前发起连接",
                  (long)_risingCount, (long)_rssiPrev, (long)r);
            _connReqAt = 0;                       // ★ 1.3.0 的 3 秒节流：预连必须能真正下发
        }
        [self forceReconnect:(isMine ? @"UUID 命中" : @"名字命中")];
    } @catch (NSException *e) { SPLog(@"link", @"didDiscover 异常: %@", e.reason); }
}

- (void)centralManager:(CBCentralManager *)cm didConnectPeripheral:(CBPeripheral *)p {
    _connects++;
    _lastConnAt = SPNow();   // ★ 1.2.15：弱信号兜底计时的起点
    _connecting = NO;    // ★ B2：连接已落地，守卫复位
    _stallRetries = 0;   // ★ A1：新链路，自愈计数归零
    _saw42 = NO;         // ★ 1.2.4：新链路，42 凭证复位
    _backoff = 1.0;      // ★ A3：连上了 → 退避归位 1 秒。
                         //   原来 backoff 是 static 局部变量，只增不减、永不复位，
                         //   封顶 30 秒后即便连成功几十次也永远 30 秒才重连。
                         //   官方 App 的 _backoff 是实例变量并在 7 处主动重置。
    _pairFails = 0;      // ★ 1.3.13-B：链路真的建起来了 → 加密/配对退避归零
    _pairFailAt = 0;
    _wr = nil; _nt = nil; _step = 0;
    _kaAt = 0;                                // ★ 1.3.13-C：GATT 重来，保活计时归零
    _redoOnLink = 0; _fff0CharsDone = NO; _fullOnce = NO;
    // ★ 1.3.0：1.2.13 恢复了「连上就解」无条件，必须撤回 —— 那是链路抖动连发的根因
    //   （1.2.12 真机：34.8 分钟 9 次断链、10 轮解锁里 8 轮自发）。但 1.2.12 的
    //   「挂起≥60s 且 距上次解锁≥600s」双门禁又把真实需求挡掉（靠近不按键不解）。
    //   1.3.0 的门禁按「按键秒解锁」目标设计：
    //     · 链路在 pending 里挂了 ≥20 秒才连上 ⇒ 车刚从睡中醒来、人走近 —— 自动解一轮；
    //     · 秒级闪断重连（车端 supervision timeout，实测 1~3 秒）⇒ 不自动解，
    //       避免「链路一抖就解一次」；这种链路上用户要开，按一下车上开关即可
    //       （按键帧直达 directBegin，不受本门禁影响）。
    //   快照必须在上面 _wr=nil 清零之前取（didDisconnect 也清了 _wr，闪断时 _wr 为 nil）。
    NSTimeInterval cnow0 = SPNow();
    BOOL sleptWake    = (_connAt > 0 && cnow0 - _connAt >= 20.0);
    BOOL flapRelink   = (_lastCarAt > 0 && cnow0 - _lastCarAt < 30.0) || _linkReady;
    _linkReady        = NO;                        // 新链路，等 GATT 就绪再置
    _unlockOnReady    = (sleptWake && !flapRelink);
    // ★ 1.3.2（C1）：自动解锁已彻底取消，这里只保留一段说明性日志。
    //   1.3.1 真机 216 分钟：37 轮解锁里 32 轮是自动的（86%），平均 6.8 分钟一次。
    //   用户目标始终是「按车辆解锁键秒解锁」，按键走 onCarFrame → directBegin 独立路径。
    SPLog(@"link", @"本次连接不自动解锁 —— 只认按键帧（挂起 %.1f 秒）",
          (_connAt > 0 ? cnow0 - _connAt : -1.0));
    (void)sleptWake; (void)flapRelink;             // 保留计算，仅用于上面的日志口径
    // ★ 1.2.6：新链路 —— 补发计数复位；_fullDiscovery 跨链路保留
    // ★ 1.2.11：_fullOnce（救急用的一次性全量）必须每条链路复位，
    //   否则一次慢回包会把后面所有链路都拖进 5 秒全量发现（1.2.10 真机实测）。
    // ★ 1.2.10：_carSendsPress 不在此重置 —— 车的发帧能力与链路无关。
    //   1.2.9 按链路记忆，实测 6 次自发解锁全部落在重连后的新链路上
    //   （14:53:54 / 14:56:12 / 14:57:43 / 14:59:15 / 16:27:49 / 16:33:45）。
    SPLog(@"link", @"✅ 已连接 %@ (累计 %ld 次)", p.name ?: @"(无名)", (long)_connects);
    p.delegate = self;
    [self stopScan:@"已连接"];
    // ★ 1.2.6：只发现 FFF0（FFF1/FFF6 所在服务）。原来 discoverServices:nil 会把车上
    //   6 个服务逐个 discoverCharacteristics，= 6 次 BLE 往返；实测「连接→写特征就绪」
    //   中位 3.0 秒、p90 5.0 秒。精简后 2 次往返，典型省约 2 秒。
    //   兜底：1.2 秒内没拿到 FFF6 → 退回全量发现（防 FFF6 不在 FFF0 的车型）。
    BOOL fullNow = (_fullDiscovery || _fullOnce);   // ★ 1.2.11：拓扑全量 或 本条链路救急全量
    [p discoverServices:(fullNow ? nil : @[ [CBUUID UUIDWithString:@"FFF0"] ])];
    if (!fullNow) {
        NSUInteger gen0 = _round;
        // 兜底第一段（1.2 秒）：FFF0 的特征已经回来、但里面没有 FFF6 ⇒ FFF6 在别的服务里。
        //   只有在「FFF0 特征确已回包」时才触发，避免特征发现稍慢就重复发起全量发现。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       SPQueue(), ^{
            if (self->_round != gen0) return;
            if (self->_wr) return;
            if (self->_car.state != CBPeripheralStateConnected) return;
            if (!self->_fff0CharsDone) return;      // FFF0 还没回，交给第二段
            SPLog(@"gatt", @"★ FFF0 特征里没有 FFF6 —— 退回全量发现");
            self->_fullDiscovery = YES;             // 记住：本机车型以后都走全量
            [self->_car discoverServices:nil];
        });
        // 兜底第二段（2.5 秒）：连 FFF0 服务本身都没回来（发现异常）⇒ 全量重来一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                       SPQueue(), ^{
            if (self->_round != gen0) return;
            if (self->_wr) return;
            if (self->_car.state != CBPeripheralStateConnected) return;
            if (self->_fff0CharsDone) return;       // 已回过，交给第一段判定
            SPLog(@"gatt", @"★ FFF0 服务发现 3.5 秒未回 —— 本条链路退回全量发现");
            self->_fullOnce = YES;                  // ★ 1.2.11：原来是 _fullDiscovery = YES —— 把「车回得慢」
                                                    //   误判成「拓扑里没有 FFF6」，且该标志只在蓝牙关闭时
                                                    //   复位（见 centralManagerDidUpdateState），一次污染整场会话。
                                                    //   真机铁证：10:34:56 FFF0 在 5.0 秒时正常回包。
            [self->_car discoverServices:nil];
        });
    }
}

- (void)centralManager:(CBCentralManager *)cm
didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    _connecting = NO;                                  // ★ B2
    SPLog(@"link", @"连接失败：%@", e.localizedDescription);
    // ★ 1.3.13-B：加密/配对类失败走指数退避 0.15 → 1 → 2 → 4 秒（封顶 4）。
    //
    //   根因（真机铁证 11-25 07:39:35–07:41:13）：
    //     07:39:35  断开（timed out）
    //     07:40:01  Failed to encrypt            ← 车拒绝加密链路
    //     07:40:01  连接失败 → 立即重连（异步）   ← 1.3.1 起就是「零延时抢跑」
    //     07:41:13  才连上（挂起 72.0 秒）        ← 中间 72 秒完全连不上
    //   车的 BLE 加密握手是有状态的：连续抢跑会让它把退避期拉长，越抢越慢。
    //   而普通掉线（车走远 / 睡着）没这个问题，维持「立即重连」最快。
    //   所以只对加密/配对类失败退避，其余不动。
    NSString *d = e.localizedDescription.lowercaseString ?: @"";
    BOOL pairFail = (e.code == 7    /* CBErrorPeerRemovedPairingInformation */ ||
                     e.code == 16   /* CBErrorEncryptionTimedOut */ ||
                     [d containsString:@"encrypt"] ||
                     [d containsString:@"pair"]);
    if (pairFail) {
        NSTimeInterval now2 = SPNow();
        if (_pairFailAt > 0 && now2 - _pairFailAt > 120.0) _pairFails = 0;  // 超过 2 分钟自动衰减
        _pairFailAt = now2;
        static const NSTimeInterval kPairBackoff[] = { 0.15, 1.0, 2.0, 4.0 };
        NSInteger idx = _pairFails;
        if (idx > 3) idx = 3;
        NSTimeInterval delay = kPairBackoff[idx];
        _pairFails++;
        SPLog(@"link", @"★ 加密/配对失败（连续第 %ld 次）—— 退避 %.2f 秒后再连",
              (long)_pairFails, delay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       SPQueue(), ^{ [self tryConnect]; });
        return;
    }
    [self retryLater:@"连接失败"];
}

- (void)centralManager:(CBCentralManager *)cm
didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    BOOL gattReady = (_wr != nil);                      // ★ 1.2.6：必须在清 _wr 之前取
    _step = 0; _wr = nil; _nt = nil; _doneLink = 0; _linkAt = 0; _saw42 = NO;
    _kaAt = 0; _kaCount = 0;                  // ★ 1.3.13-C：新链路，保活计时归零
    _doneAt = 0; _redoOnLink = 0; _lastCarAt = 0;       // ★ 1.2.7：新链路，时效窗/补发计数/车帧时刻作废
    _unlockOnReady = NO;                                // ★ 1.3.0：链路作废
    //   注意：_linkReady 不清 —— 它是「上一条链路 GATT 曾就绪」的快照，didConnect
    //   靠它区分「睡醒首连（自动解）」和「闪断重连（不自动解）」，在那里才复位。
    // ★ 1.2.1：冷却锚点也必须随链路作废。1.2.0 在这里清了一堆状态却漏了 _lastAt，
    //   导致「发到一半链路被断 → 立刻重连 → 新链路就绪」时，directBegin 被上一条链路的
    //   20 秒冷却在第 545 行静默 return（零日志），只能等 SPTick 下一拍补发。
    //   真机铁证（2026-10-10 日志）：20:37:31 就绪 → 20:37:59 才发出帧1（+28s，正是用户
    //   「按了两次」的那一回）；21:09:23 就绪 → 21:09:34 才发出（+11s，恰为定时器第 701 拍）。
    //   断开即新一轮，新链路必须能立刻直发。
    _lastAt = 0;                                        // ★ 1.2.1：清冷却，新链路不受上一轮影响
    _connecting = NO; _stallRetries = 0; _round++;      // ★ B2/A1：链路已断，守卫与看门狗全作废
    SPLog(@"link", @"⚠️ 断开：%@", e ? e.localizedDescription : @"主动/正常断开");
    // ★ 1.2.9：这条断线是我们主动取消卡死连接造成的 —— 重连已排程，不要再排一次。
    if (_stuckCancel) {
        _stuckCancel = NO;
        SPLog(@"link", @"（主动取消后的断线回调 —— 重连已排程，不重复）");
        // ★ A6 修复（秒解锁）：**必须保住扫描**，否则会永久失明。
        //   1.3.8 真机铁证（10-30 21:45 → 10-31 12:54，10 小时）：
        //     27 次断开里只有 5 次随后「开始扫描」，22 次僵尸取消后**一次都没扫**。
        //   原因就是这个 return —— 它跳过了 retryLater，而 retryLater 才是
        //   tryConnect → beginScan 的唯一入口。结果：取消之后既不扫描也不重连，
        //   只能干等 SPTick 的 15 秒心跳拍，期间完全看不到车在不在广播。
        //   而 A5（车在广播就立刻重连）的触发源正是扫描回调 —— 不扫描 ⇒ A5 永不触发。
        //   真机佐证：10 小时里「车在广播但链路断开」= 0 次，A5 形同虚设。
        //   实测代价：11:46:08 连上 → 11:46:58 超时断 → 11:48:18 才连上，
        //   中间空了 80 秒；用户若早按 30 秒，那一帧就永远丢失（车不重发）。
        //
        //   两步都要做：
        //   ① 立刻开始扫描 —— 车一广播，A5 就能在 1 秒内把连接推上去；
        //   ② 0.3 秒后主动下发一次连接 —— 车若本来就在广播范围内，不等扫描回调直接连。
        //      0.3 秒是为了让 CoreBluetooth 把 cancel 的状态机走完（参考 1.2.6 的抢连值）。
        // ★ 1.3.10-C 附带：A6 分支同样有「_scanning 标志失步」风险，
        //   beginScan 第一行的 `if (… || _scanning) return;` 会让它静默失效。
        //   先无条件 stopScan 复位数扫描标志，再 beginScan。
        //   1.3.9 日志：190 次 START / 184 次 STOP，差 6 次即标志未配对。
        [self stopScan:@"A6 前复位扫描标志"];
        [self beginScan:@"僵尸取消后保活扫描（A6）"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       SPQueue(), ^{
            if (self->_cm.state != CBManagerStatePoweredOn) return;
            if (!self->_car || self->_car.state == CBPeripheralStateConnected) return;
            self->_connecting = YES;
            self->_connAt = SPNow();     // 新请求重新计时，避免立刻又被判僵尸
            [self->_cm connectPeripheral:self->_car options:SPConnectOptions()];
        });
        return;
    }
    // ★ 1.2.6：GATT 未就绪就断 = 车刚醒 / 闪断（实测占全部链路的 20.8%）。
    //   等 1 秒再连会错过车的唤醒窗口，改为 0.3 秒抢连。
    if (!gattReady) _backoff = 0.3;
    [self retryLater:@"断开"];
}

- (void)retryLater:(NSString *)why {
    // ★ 1.3.1（A）：掉线后**立即重连**，不再 1→2→4 秒退避。
    //   1.3.0 真机（360 分钟，车在 30 米内 RSSI 中位 -94）：
    //     12 次连接在线共 1284 秒 / 21616 秒 = 可用率仅 5.9%；
    //     链路寿命 2s / 6s / 16s / 24s / 31s / 37s / 92s / 123s / 207s / 278s / 466s。
    //   退避在这条链路质量下是纯损失：断开本身就意味着「已经浪费了一段时间」，
    //   再退避 1~4 秒只会把按键落空窗口进一步放大 —— 而按键帧只能靠已建链路承载
    //   （真机 10:36:13 / 11:03:37 两次按键命中，都是刚好落在链路活着的窗口里）。
    //   ★ 1.3.12（A1）：去掉 0.15 秒定时器，改 dispatch_async。
    //   这个延时唯一的目的是「别在 CoreBluetooth 的断开回调栈里直接发起连接」，
    //   下一轮 runloop 就够，不必白等一个定时器。
    //   真机账（11-18，16.2 小时 / 393 次断开）：断开→连上中位 12.0 秒，0.15 占 0.9%。
    _backoff = 1.0;                              // 保留字段语义，但不再用于延时
    SPLog(@"link", @"%@ → 立即重连（异步）", why);
    dispatch_async(SPQueue(), ^{                                    // ★ B1
        [self tryConnect];
    });
}

//──────────────────────── 链路保活（1.3.13-C）────────────────────────
//   目的：连上之后不要再「一声不吭被动等按键帧」。
//   真机账（11-23→11-25，23 次连接）：寿命中位 31 秒，7 次只有 1~10 秒；
//   但同时存在 688 / 611 / 537 / 510 秒的长命链路 —— 车本身肯长连。
//   短命那批最可能是「链路全程零流量，车端判定空闲后清扫」。
//   每 20 秒打一次 ATT 往返，把链路维持住，减少「按下去时链路已经没了」。
//
//   ★ 为什么不直接往 FFF6 写自定义字节：
//     FFF6 是车的应用层命令通道，解锁四帧就走它。车端协议是有状态的
//     （55 55 len cmd seq ...），塞进它没预期的帧，轻则被忽略，重则触发车端
//     异常分支 —— 而我们从没在真机上验证过车对未知帧的反应。
//     所以优先用**纯 ATT 层**动作，车端应用层看不见：
//       ① 特征支持 Read  → readValueForCharacteristic（ATT read）
//       ② 否则           → 重写 FFF1 的 CCCD 通知开关（ATT write，spec 层）
//     两条都会产生真实的链路往返，且不改车端任何状态。
//     真要改成写 FFF6，把下面的 kKaWriteFFF6 置 YES 即可，风险自负。
- (void)keepAlive {
    if (!_armed) return;
    if (!_cm || _cm.state != CBManagerStatePoweredOn) return;
    if (!_car || _car.state != CBPeripheralStateConnected) return;
    if (!_wr) return;                                  // GATT 未就绪，没得保活
    if (_step != 0) return;                            // 解锁流程在跑，绝不插帧
    NSTimeInterval now3 = SPNow();
    if (now3 - _kaAt < 20.0) return;                   // 20 秒一次
    _kaAt = now3;

    static BOOL kKaWriteFFF6 = NO;                     // ← 想直接写 FFF6 就改这里
    NSString *how = nil;
    if (kKaWriteFFF6) {
        static const unsigned char ack[7] = { 0x55, 0x55, 0x1A, 0x02, 0x00, 0x01, 0x01 };
        [_car writeValue:[NSData dataWithBytes:ack length:sizeof(ack)]
      forCharacteristic:_wr type:CBCharacteristicWriteWithResponse];
        how = @"写 FFF6 应答帧";
    } else if (_wr.properties & CBCharacteristicPropertyRead) {
        [_car readValueForCharacteristic:_wr];
        how = @"读 FFF6";
    } else if (_nt && (_nt.properties & CBCharacteristicPropertyRead)) {
        [_car readValueForCharacteristic:_nt];
        how = @"读 FFF1";
    } else if (_nt) {
        [_car setNotifyValue:YES forCharacteristic:_nt];   // CCCD 重写，纯 ATT 层
        how = @"重写 FFF1 通知开关";
    } else {
        return;                                        // 没有任何安全手段，放弃
    }
    _kaCount++;
    if (now3 - _kaLogAt > 300.0) {                     // 5 分钟一条，不刷屏
        _kaLogAt = now3;
        SPLog(@"link", @"保活 #%ld（%@，间隔 20 秒）", (long)_kaCount, how);
    }
}

//──────────────────────── CBPeripheralDelegate ────────────────────────
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)e {
    for (CBService *s in p.services) {
        SPLog(@"gatt", @"服务 %@", s.UUID.UUIDString);
        if ([s.UUID.UUIDString caseInsensitiveCompare:@"FFF0"] == NSOrderedSame) {
            // ★ 1.2.6：只问 FFF1/FFF6，省掉同服务内其它特征的往返
            [p discoverCharacteristics:@[ [CBUUID UUIDWithString:@"FFF1"],
                                          [CBUUID UUIDWithString:@"FFF6"] ]
                            forService:s];
        } else if (_fullDiscovery || _fullOnce) {   // ★ 1.2.11：救急全量也要把其它服务的特征问全
            // ★ 1.2.6：只有兜底模式下才逐个发现其它服务（正常路径省 5 次往返 ≈ 2 秒）
            [p discoverCharacteristics:nil forService:s];
        }
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
    if ([svc.UUID.UUIDString caseInsensitiveCompare:@"FFF0"] == NSOrderedSame) _fff0CharsDone = YES;   // ★ 1.2.6
    if (_wr && _nt && !_nt.isNotifying) {
        [p setNotifyValue:YES forCharacteristic:_nt];
        SPLog(@"gatt", @"订阅 FFF1（车的回帧从这条来）");
    }
    if (_wr) {
        _linkAt = SPNow();                             // ★ C3：记号：本链路
        _linkReady = YES;                              // ★ 1.3.0：本链路 GATT 已就绪（闪断重连判定用）
        SPLog(@"gatt", @"写特征 FFF6 就绪 —— 请求直发");
        // ★ 1.3.0：GATT 就绪后是否立刻发一轮，由 didConnect 里的「睡醒补一次」门禁
        //   决定（_unlockOnReady）。链路抖动秒级重连不再自动解（那是 1.2.12/1.2.13
        //   的自发连发根因）；按键路径不走这里（onCarFrame 带 _forceSend 直调
        //   directBegin），「靠近 → 按键 → 秒解锁」不受影响。
        // ★ 1.3.2（C1）：彻底取消「GATT 就绪就自动解一轮」。
        //   1.3.1 真机（216 分钟，链路可用率已升到 55.3%）：37 轮解锁里**只有 5 轮是
        //   用户按的，其余 32 轮全自动**（平均每 6.8 分钟车自己解开一次）。
        //   根因：1.3.0 的「睡醒补一次」用 _connAt 挂起时长判「车是否刚醒」，但在
        //   弱信号下链路频繁断开重连（41 次），每次重连都满足 sleptWake 条件，
        //   A（掉线即刻重连）把链路修好之后，反而把这个副作用放大了 9 倍。
        //   关键事实：**按键路径根本不经过这里**（onCarFrame 带 _forceSend 直调
        //   directBegin），所以删掉这段不影响「按键秒解锁」——
        //   真机 5/5 全中：1243 / 1315 / 1275 / 1345 / 1282 ms。
        //   而用户的目标从来是「按车辆解锁键秒解锁」，不是「走近自己开」。
        _unlockOnReady = NO;                           // ★ 1.3.2：永不自发解锁
        SPLog(@"direct", @"本链路不自动解锁 —— 只认按键帧（1.3.2/C1）");
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
    // ★ 1.2.7：hex 采样（只读）—— 用来区分「按键帧 / 握手回复帧 / 收尾帧」
    {
        NSMutableString *hex = [NSMutableString stringWithCapacity:ch.value.length * 3];
        const uint8_t *bp = (const uint8_t *)ch.value.bytes;
        for (NSUInteger i = 0; i < ch.value.length && i < 48; i++) [hex appendFormat:@"%02X ", bp[i]];
        SPLog(@"car", @"   车帧 hex=%@", hex);
    }
    // ★ 1.2.8：按键帧 / 解锁后状态帧的字节是**固定**的（真机两次按下逐字节相同），
    //   直接按字节认，比 4 秒时间闸门可靠 —— 状态帧迟到多久都不会被误判成按键。
    //   未知帧型仍走时间闸门兜底，不丢新车型。
    {
        NSTimeInterval cnow = SPNow();
        // ★ 1.3.11：同一个 1e9 哨兵又被拼进日志了（「空闲 1000000000.0 秒」7 条）。
        //   判据照旧用 gap，展示走 gapKnown。
        BOOL gapKnown = (_lastCarAt > 0);
        NSTimeInterval gap = gapKnown ? (cnow - _lastCarAt) : 1e9;
        _lastCarAt = cnow;
        if (_step == 0 && ch.value.length == 26) {
            const uint8_t *b = (const uint8_t *)ch.value.bytes;
            BOOL isPress  = (memcmp(b, kPressFrame, 26) == 0);
            BOOL isStatus = (memcmp(b, kStatusFrame, 26) == 0);
            if (isStatus) {
                // ★ 1.2.9：状态帧既在解锁后 0.3 秒出现（回执），也在静默 288.7 秒后单独出现
                //   （1.2.8 08:09:50 实测）。带上「距上次解锁多久」才能分清两种语义，
                //   为后续「车已锁 ⇒ 才允许解锁」的门禁铺路。
                NSTimeInterval sinceDone = (_doneAt > 0) ? (SPNow() - _doneAt) : -1.0;
                // ★ 1.2.11：原来是 %s + C 字面量 —— SPLog 走 NSString initWithFormat:，
                //   其中 %s 按**系统编码**解释（iOS 上是 MacRoman），而字面量是 UTF-8，
                //   结果双重编码成「Áñë‰ººËΩ¶Áä∂ÊÄÅÂèòÊõ¥」（真机日志实证）。
                //   改用 %@ + NSString 字面量，彻底绕开编码问题。
                // ★ 1.3.11：sinceDone 的 -1.0 与 gap 的 1e9 都是哨兵，不能原样进日志。
                //   1.3.10 真机出现过「距上次解锁 -1.0 秒，空闲 1000000000.0 秒」。
                NSString *doneText = (_doneAt > 0)
                    ? [NSString stringWithFormat:@"距上次解锁 %.1f 秒", sinceDone]
                    : @"此前从未解锁过";
                NSString *statusGapText = gapKnown
                    ? [NSString stringWithFormat:@"空闲 %.1f 秒", gap]
                    : @"本次会话首帧";
                SPLog(@"direct", @"状态帧 —— 忽略（%@，%@，%@）",
                      doneText, statusGapText,
                      (sinceDone < 0 || sinceDone > 60.0) ? @"疑似车状态变更" : @"解锁回执");
                return;                 // 永不当按键
            }
            if (isPress || gap > 4.0) {
                NSString *pressGapText = gapKnown
                    ? [NSString stringWithFormat:@"空闲 %.1f 秒", gap]
                    : @"本次会话首帧";
                SPLog(@"direct", @"★ 车主动发帧（%@，%@）—— 判定为开关按下，立即发帧",
                      isPress ? @"字节直认" : @"时间闸门", pressGapText);
                _redoOnLink = 0;        // ★ 1.2.8：真实按键 → 兜底额度复位
                _carSendsPress = YES;    // ★ 1.2.10：全局记忆 —— 重连不重置，本车永久关闭定时兜底
                if (!isPress) {
                    NSMutableString *u = [NSMutableString string];
                    for (NSUInteger i = 0; i < 26; i++) [u appendFormat:@"%02X ", b[i]];
                    SPLog(@"direct", @"   未知帧型（待归类）hex=%@", u);
                }
                _forceSend = YES;
                [self directBegin];
                _forceSend = NO;
                return;                 // 按键帧不参与握手解析
            }
        }
    }
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
        } else {
            [u keepAlive];      // ★ 1.3.13-C：链路在就每 20 秒打一次 ATT 往返
        }
        // ★ 1.3.2（C1）：删掉这里原本的 `[u directBegin]`。
        //   1.3.1 真机 216 分钟：37 轮解锁里只有 5 轮是用户按的，其余 **32 轮全自动**
        //   （平均每 6.8 分钟车自己解开一次）。主因就是这一句 —— SPTick 每 15 秒一拍，
        //   只要「已连接 + 写特征就绪 + 空闲」，就去 directBegin 试一发。
        //   而新链路 _doneLink != _linkAt，directBegin 内部的「本链路已完成」守卫不成立
        //   ⇒ 每重连一次，最多 15 秒内必然自动解一轮。1.3.1 的 A（0.15 秒即刻重连）
        //   把重连次数从 12 拉到 41，于是自动解锁从 9 次涨到 32 次 —— 修好链路的副作用。
        //   按键路径完全独立（onCarFrame → _forceSend + directBegin），不受影响：
        //   真机 5/5 全中，1243 / 1315 / 1275 / 1345 / 1282 ms。
        //   握手自愈（armWatchdog 里的 8 秒重发）也保留，它只在 _step != 0 时触发。
    } @catch (NSException *e) { /* 吞 */ }
}

//════════════════════════════ 入口（纯 Objective-C，替代 Logos %ctor）════════════════════════════
#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "dev"
#endif
__attribute__((constructor)) static void SPInit(void) {
    @try {
        os_log(OS_LOG_DEFAULT, "ApelinLoaded %{public}s", APELIN_BUILD_ID);
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
