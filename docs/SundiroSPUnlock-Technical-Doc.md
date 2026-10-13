# SundiroSPUnlock —— 插件技术文档

> 新大洲本田蓝牙**无感解锁** · SpringBoard 插件
> 把「连车 + 发四帧解锁」从官方 App 里完全独立出来，直接跑在 SpringBoard 内。
> 其余功能（车况遥测 / 小组件 / 深链）继续由官方 App 侧负责，互不干扰。

最后更新：**2026-10-13** ｜ 对应版本：**1.2.3（现行）**

---

## 目 录

1. [一句话原理](#1-一句话原理)
2. [交付物与版本](#2-交付物与版本)
3. [工程结构](#3-工程结构)
4. [包信息（control）](#4-包信息control)
5. [运行机制：完整时序](#5-运行机制完整时序)
6. [解锁协议详解](#6-解锁协议详解)
7. [车辆识别（怎么找到车）](#7-车辆识别怎么找到车)
8. [配置开关](#8-配置开关)
9. [日志系统](#9-日志系统)
10. [安全设计](#10-安全设计)
11. [版本演进史（每轮抓到的真 Bug）](#11-版本演进史每轮抓到的真-bug)
12. [真机验收数据](#12-真机验收数据)
13. [已知限制与待办](#13-已知限制与待办)
14. [构建与发布流程](#14-构建与发布流程)
15. [排障速查表](#15-排障速查表)

---

## 1. 一句话原理

**iOS 会无限期保持一个「挂起的蓝牙连接」（pending connect）。**
插件在 SpringBoard 里挂上这个连接，然后什么都不做 —— 车一进入范围，iOS 自动完成连接，
插件立刻走 GATT 发四帧解锁。

- 官方 App 也能做这件事，但**会被 iOS 挂起**
- **SpringBoard 永远不会被挂起** —— 这就是插件存在的意义

实测铁证：pending connect 存活 **6 小时 26 分**，期间零人工干预，车一出现即连接并解锁。

---

## 2. 交付物与版本

### 最新：1.2.3（2026-10-10 发布，10-13 复核）

| 文件 | 架构 | 说明 |
|---|---|---|
| `com.jibamao.spsundiro_1.2.3_iphoneos-arm64e.deb` | arm64e | **RootHide / Dopamine-roothide 装这个** |
| `com.jibamao.spsundiro_1.2.3_iphoneos-arm64.deb` | arm64 | rootless / Dopamine 用这个 |
| `SundiroSPUnlock-1.2.3-Source.zip` | — | 完整干净源码 |
| `SHA256SUMS` | — | 校验文件 |

> 资产 sha256（与 GitHub Release 逐字节复核一致）：
> arm64e `60f1e1d0…` ｜ arm64 `7855fa62…` ｜ Source.zip `fc92fcef…`
>
> **已上架自建 Sileo 源**：`https://gan-jibamao.github.io/`

> **两个架构不可同时安装。** 判断方法：RootHide 的插件真实载荷在 `/Library/...`，
> rootless 的在 `/var/jb/Library/...`。

### 发布地址

- Releases：`https://github.com/gan-jibamao/SundiroSPUnlock/releases`
- 仓库：`https://github.com/gan-jibamao/SundiroSPUnlock`

---

## 3. 工程结构

```
SundiroSPUnlock/
├── Makefile                    # Theos 构建配置（11 行）
├── control                     # 包元信息（16 行）
├── SundiroSPUnlock.plist       # 注入过滤器（20 行）
├── Tweak.x                     # 全部逻辑（875 行，51.6 KB）
├── README.md
├── .github/workflows/build.yml # CI：macOS + roothide/theos 双架构
└── .gitignore
```

### Tweak.x 内部结构（按段落）

| 行范围 | 段落 | 内容 |
|---|---|---|
| 1–148 | 头部 | 架构注释、宏定义、协议常量（`kUnlockConst32` + 49 组 `kUnlockPairs`） |
| 149–212 | 工具 | 专用串行队列 / 单调时钟 / 多根路径探测（1.2.0 新增） |
| 213–362 | 日志模块 | `SPLog` / `SPLogInit` / 日志轮转 / `SPFlag` |
| 363–379 | 造帧 | `SPFrame(...)` |
| 380–820 | **解锁器** | `SPUnlocker` 类：扫描、连接、四帧握手、委托回调 |
| 831–853 | 常驻驱动 | `SPTick`（C 函数，15 秒心跳） |
| 854–875 | 入口 | `%ctor` 构造器 |

### 复杂度速览

| 指标 | 数值 |
|---|---|
| 源码行数 | **875** 行（1.1.6 为 693 行） |
| 协议常量 | **1600** 字节（49 组配对 ×32B + 32B 常量） |
| 依赖框架 | **2** 个（Foundation、CoreBluetooth） |
| 配置开关 | **2** 个（`enable`、`unlock`） |
| 日志候选路径 | **6**（探测后只写命中的单一可写路径，1.2.0/D1） |
| 类 | **1** 个（`SPUnlocker`） |

---

## 4. 包信息（control）

```
Package:      com.jibamao.spsundiro
Name:         Sundiro BLE Unlock (SpringBoard)
Version:      1.1.2
Architecture: iphoneos-arm64e
Maintainer:   jibamao
Author:       jibamao
Section:      Tweaks
Replaces:     com.huayuarc.spsundiro      ← 旧包名，装新版自动顶掉
Conflicts:    com.huayuarc.spsundiro
Depends:      mobilesubstrate
```

### 注入过滤器（`SundiroSPUnlock.plist`）

| 键 | 值 | 说明 |
|---|---|---|
| `Bundles` | `com.apple.springboard` | 主目标 |
| | `com.apple.Preferences` | **对照组**：打开「设置」若能出日志，说明注入链路通、问题在 SpringBoard 专属策略。上线后可删 |
| `Executables` | `SpringBoard` | 双保险（只写 Bundles 时实测无效） |

### Makefile

```makefile
TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME ?= roothide          # 可被 CI 覆盖为普通 rootless
TWEAK_NAME = SundiroSPUnlock
SundiroSPUnlock_FILES = Tweak.x
SundiroSPUnlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SundiroSPUnlock_FRAMEWORKS = Foundation CoreBluetooth
```

> ⚠️ 源文件必须是 **`.x`**（ObjC），不能用 `.xm`（ObjC++）。
> `.xm` 在 CI 的编译器下会因 `const void*` → `const unsigned char*` 隐式转换而报错。

---

## 5. 运行机制：完整时序

### 5.1 启动（构造器）

```
%ctor
 ├─ ① 检查 kill-switch（停用标记文件）→ 存在则直接 return   ★ 永远是第一件事
 ├─ ② SPLogInit()  初始化日志路径
 ├─ ③ 打装载日志（版本 / pid / uid / bundle）
 ├─ ④ 读 enable 开关 → 为假则退出
 └─ ⑤ dispatch_async 到后台队列：
       gUnlocker = [SPUnlocker new]      ★ 静态强持有（关键！）
       [gUnlocker start]
       SPTick(gUnlocker)                 启动 15 秒常驻驱动
```

**为什么必须静态强持有？**
`CBCentralManager.delegate` 是 **weak** 引用。若用块内局部变量，块一结束实例就被 ARC 回收
→ delegate 变 nil → `centralManagerDidUpdateState` 永远不回调（1.0.5 实测就是卡在这里）。

### 5.2 `start`（起蓝牙引擎）

```
start
 ├─ 防重入：_cm 已存在则直接返回
 ├─ ★ 只在 bundle == com.apple.springboard 时起引擎
 │    （其它宿主只留一颗信标日志，方便对照组）
 ├─ _backoff = 1.0                   ★ 退避初值（必须在建 _cm 之前）
 └─ _cm = [[CBCentralManager alloc] initWithDelegate:self queue:全局工具队列 options:opt]
```

> ⚠️ **绝不能带 `CBCentralManagerOptionRestoreIdentifierKey`！**
> iOS 只允许声明了 `bluetooth-central` 后台模式的 App 做状态恢复；SpringBoard 没有这个 key，
> 带上会抛 `NSInternalInconsistencyException`（1.0.4 实测）。
> SpringBoard 是常驻进程，**根本不需要**状态恢复 —— 这是从 App 版移植过来的历史包袱。
>
> 唯一保留的选项：`CBCentralManagerOptionShowPowerAlertKey: @NO`（不弹「打开蓝牙」提示）

### 5.3 常驻驱动 `SPTick`（每 15 秒）

```c
static void SPTick(SPUnlocker *u) {
    // ★ 先续期、再干活 —— 否则 armed 还是 NO 时提前 return，循环只跑一次就断（1.0.6 实测）
    dispatch_after(15s, ..., ^{ SPTick(u); });

    u.ticks++;
    if (u.armed && (u.ticks % 8) == 0) {          // 每 8 跳 ≈ 2 分钟
        心跳日志：外设状态 / 已连 / 已解锁 / 步 / 写特征有无
    }
    if (!u.armed) return;
    if (!u.car || u.car.state != CBPeripheralStateConnected) [u tryConnect];
    else if (u.wr && u.step == 0) [u directBegin];
}
```

**心跳的用途**：证明插件存活；pending connect 若被系统悄悄撤掉，日志上能看出来。

### 5.4 认车与连接

```
tryConnect
 ├─ _cm 状态必须是「已开启」，否则返回
 ├─ 若还没有车对象：
 │   ├─ 读车名（App 容器 sb.vehicle.name）
 │   ├─ 读车辆 UUID（App 容器 sb.vehicle）
 │   └─ retrievePeripheralsWithIdentifiers([UUID])
 │        ├─ 命中 → adopt（认车）
 │        └─ 未命中 → 记下 UUID，转扫描
 ├─ 若还没有车对象 → beginScan（全设备扫描）
 ├─ 状态已是 Connected / Connecting → 静默返回（不打扰）
 └─ connectPeripheral:_car          ← 挂出 pending connect
```

**扫描策略**：全设备扫描（**不限定 FFF0 服务 UUID**）+ 名字前缀 `SDH-` / 已知 UUID 双重匹配，
扫描窗口 25 秒、冷却 20 秒。
> 为什么不限定 FFF0：App 版一直靠 `retrieve` 已知 UUID 连车，**从未真正跑过扫描**，
> 「车广播里一定带 FFF0」这点从未被验证，所以选择更保险的全扫。

### 5.5 连接成功后（GATT 链路）

```
didConnectPeripheral
 ├─ _connects++
 ├─ _backoff = 1.0          ★ A3：连上即复位退避
 ├─ _wr = nil; _nt = nil; _step = 0
 ├─ 打日志「✅ 已连接」
 ├─ p.delegate = self       ★ 必须设！否则后续所有 GATT 回调都收不到
 ├─ stopScan
 └─ discoverServices:nil

didDiscoverServices         → 逐个服务 discoverCharacteristics:nil
didDiscoverCharacteristicsForService
 ├─ 若 _wr && _nt 已齐 → 直接 return（A2：防重复回调刷屏）
 ├─ 挑出 FFF1（通知特征）→ _nt；FFF6（写特征）→ _wr
 ├─ 订阅 FFF1（未订阅时）
 ├─ _linkAt = now           ← 本链路握手时刻
 └─ directBegin()           ← 立刻直发（不等订阅确认回调）

didUpdateNotificationStateForCharacteristic
 └─ 打「FFF1 订阅已生效 / 被关闭 / 失败」   ★ 回帧通道是否打通的唯一凭据

didUpdateValueForCharacteristic
 ├─ 记 _lastCarFrame
 ├─ 打「← 车回帧 FFF1 len=N」
 └─ onCarFrame(数据)        ← 推进握手
```

### 5.6 断线与重连

```
didDisconnectPeripheral
 ├─ _step = 0; _wr = nil; _nt = nil; _doneLink = 0; _linkAt = 0
 ├─ 打日志「⚠️ 断开」
 └─ retryLater

didFailToConnectPeripheral
 ├─ 打日志「连接失败」
 └─ retryLater

retryLater
 ├─ d = MIN(_backoff, 30)
 ├─ _backoff = MIN(_backoff * 2, 30)    退避 1 → 2 → 4 → 8 → 16 → 30
 ├─ 打日志「断开 → N 秒后重试」
 └─ N 秒后 tryConnect
```

**A3 的关键**：`_backoff` 是**实例变量**，在 `didConnectPeripheral` 里复位为 1.0。
（此前是 `static` 局部变量，只增不减、全工程无重置点 → 封顶后**永远 30 秒**）

---

## 6. 解锁协议详解

### 6.1 服务与特征

| UUID | 用途 |
|---|---|
| `0000FFF0-0000-1000-8000-00805F9B34FB` | 目标服务（车同时还有 1800 / 1801 / D0FF / 180A / 1812） |
| `FFF6` | **写特征** —— 四帧解锁报文写这里 |
| `FFF1` | **通知特征** —— 车的回帧从这里回来（**必须订阅**） |

> 特征匹配用 `caseInsensitiveCompare:@"FFF6"` 全等比较 —— CoreBluetooth 对 16 位特征返回短形式，
> 与应用已验证可用的官方实现一字不差。

### 6.2 报文格式 `SPFrame`

```
偏移  长度  内容
 0     2    55 55                帧头
 2     1    10 + payloadLen      长度
 3     1    cmd
 4     1    seq
 5     1    status
 6     1    tag
 7     N    payload
 7+N   1    XOR 校验（整帧异或）
 8+N   2    AA AA                帧尾
```

### 6.3 四帧握手（**挑战—应答，不是盲发**）

```
① 帧 1/4   SPFrame(0x02, 0x00, 0x01, 0xFE,  R(16B) + kUnlockConst32(32B), 48)   → 58 字节
              ↓ 等车回帧（26 或 42 字节）
② 帧 2/4   SPFrame(0x00, 0x01, 0x00, 0xFA,  NULL, 0)                            → 10 字节
              ↓ 等车回帧（42 或 26 字节）
③ 帧 3/4   SPFrame(0x02, 0x02, 0x03, 0xFA,  R3(16B), 16)                        → 26 字节
              ↓ 等车回帧（必须 26 字节）
④ 帧 4/4   SPFrame(0x00, 0x03, 0x04, 0xFA,  NULL, 0)                            → 10 字节
              ★ 完成
```

**每发一帧必须等车回帧才推进下一帧**，回帧走 **FFF1 notify**。
若帧 1 发出后 **3 秒**无回帧 → 放弃本轮（`_step` 归零）。

状态机 `_step`：`0` 空闲 ｜ `1` 已发帧1 ｜ `2` 已发帧2 ｜ `3` 已发帧3 ｜ `4` 已发帧4

### 6.4 配对表

```c
static const unsigned char kUnlockConst32[32] = { 0xB8,0xBE,... };      // 32 字节固定常量
static const struct {
    unsigned char r[16];
    unsigned char r3[16];
} kUnlockPairs[49] = { ... };                                            // 49 组
```

- 帧 1 的 payload = `R(16B)` + `kUnlockConst32(32B)`
- 帧 3 的 payload = `R3(16B)`，**取自与帧 1 同一组配对**（`_pick` 已自增，取 `_pick-1`）
- 每轮握手后 `_pick++`，49 组轮换使用
- **协议常量总量 1600 字节**，原样抠自官方 App 源码第 94–198 行

### 6.5 抑制重复解锁

| 机制 | 说明 |
|---|---|
| `_doneLink == _linkAt` | 本链路已完整发过一轮 → 不再重发（**断开时清零**，下次靠近照样解锁）|
| `_lastAt` 冷却 20 秒 | 断/连抖动时不刷帧 |
| `_step != 0` | 握手进行中不重开 |
| `_linkAt` | 本链路握手时刻（`CBPeripheral` 没这属性，自己记）|

> **A1 修复点**：`_doneLink` 此前是**死守卫** —— 全工程只读、从未赋非零值，
> 判重恒为假 ⇒ 车已解锁仍每 ~30 秒（15s tick × 20s 冷却）重发一轮。
> 实测：8 分钟发了 17 次。修复后同场景只发 1 次。
> 修法：第 4 帧完成后补 `_doneLink = _linkAt;`

---

## 7. 车辆识别（怎么找到车）

### 7.1 首选：已知 UUID（retrieve）

```
读 sb.vehicle ← /var/mobile/Containers/Data/Application/<App-UUID>/Library/Preferences/com.sundirohonda.app.plist
       ↓
retrievePeripheralsWithIdentifiers([NSUUID])
       ↓
命中 → 直接 adopt，无需扫描
```

### 7.2 读 App 容器的两条路（**关键坑**）

官方 App 用的是 **`[NSUserDefaults standardUserDefaults]`**（不是 suite），
所以数据存在 **App 自己的容器**里，从 SpringBoard **不能**用 `initWithSuiteName:` 读到。

| 顺序 | 方法 | 说明 |
|---|---|---|
| ① | `CFPreferencesCopyValue(key, CFSTR("com.sundirohonda.app"), kCFPreferencesAnyUser, kCFPreferencesAnyHost)` | cfprefsd 跨用户域读 |
| ② | 直接扫文件系统 | `.../Data/Application/*/Library/Preferences/com.sundirohonda.app.plist` 与 `.../Shared/AppGroup/*/Library/Preferences/group.com.carbit.edrive.honda.plist` |

读取的键：

| 键 | 内容 |
|---|---|
| `sb.vehicle` | 车辆 UUID |
| `sb.vehicle.name` | 车名（实测 `SDH-xxxxxx`）|

### 7.3 兜底：扫描 + 双重匹配

全设备扫描后，满足**任一**条件即认车：

1. UUID 命中已知车辆 UUID
2. 名字以 `SDH-` 开头（`CBAdvertisementDataLocalNameKey` 优先，其次 `p.name`）

非目标但有名字的设备会打 `旁侧设备 <名字> RSSI=<值>` 便于诊断。

---

## 8. 配置开关

读自偏好域 **`com.jibamao.spsundiro`**：

| 键 | 默认 | 作用 |
|---|---|---|
| `enable` | `YES` | 主开关。为 `NO` 时构造器直接退出（不起蓝牙引擎）|
| `unlock` | `YES` | 是否真正发解锁帧（`directBegin` 入口判断）|

### 停用 / 恢复

| 操作 | 命令 |
|---|---|
| **立即停用** | `touch /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` 然后 `killall -9 SpringBoard` |
| **恢复** | `rm /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` |
| 单独关解锁 | 偏好域写 `unlock = NO`（仍保持连接，只是不发帧）|

---

## 9. 日志系统

### 9.1 路径

默认：**`/var/mobile/Library/Logs/sundirosp.log`**

可用配置文件 `com.jibamao.spsundiro.logpath` 覆盖。**其余 5 个候选路径**（应对沙盒/RootHide 差异）：

```
/var/mobile/Library/Preferences/com.jibamao.spsundiro.log
/var/mobile/Documents/sundirosp.log
/var/jb/var/mobile/Library/Logs/sundirosp.log
/tmp/sundirosp.log
/var/tmp/sundirosp.log
```

- **轮转**：超过 **512 KB** 自动改名为 `.1`
- **同时**写 `NSLog`（Console 可读，沙盒拦不住）

### 9.2 日志标签

| 标签 | 含义 |
|---|---|
| `[boot]` | 启动 / 装载 / 蓝牙状态 |
| `[probe]` | 车辆 UUID / 车名读取过程（诊断用）|
| `[link]` | 扫描 / 认车 / 连接 / 断开 / 重试 |
| `[gatt]` | 服务与特征发现 / FFF1 订阅状态 |
| `[direct]` | 四帧握手推进 |
| `[car]` | 车的回帧 |
| `[life]` | 每 2 分钟心跳 |

### 9.3 ★ 血泪教训：日志格式化必须用 ObjC

```c
// ✗ 错的：C 的 vsnprintf 不认识 %@
vsnprintf(buf, ...);

// ✓ 对的：用 ObjC 格式化
NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
```

**后果**：用 C 的 `vsnprintf` 时 `%@` 会退化成 `@`，并让**后续参数整体错位** ——
实测导致 pid/uid 变乱码、异常内容整条丢失（日志只剩 `启动异常: @`），
直接耽误了一轮排查。

---

## 10. 安全设计

**前提：SpringBoard 崩溃 = 设备注销；开机崩溃 = 白苹果循环。** 所以设计上极度保守：

| # | 措施 |
|---|---|
| 1 | **kill-switch 是构造器第一件事** —— 标记文件存在就直接 return，任何代码都不执行 |
| 2 | **全部逻辑在后台队列**（`QOS_CLASS_UTILITY`），不阻塞 SpringBoard 启动路径 |
| 3 | **逐层 `@try/@catch`** —— 构造器、`SPTick`、每个 delegate 回调、`directBegin`、`onCarFrame` 全部包异常，**绝不让异常外泄到 SpringBoard** |
| 4 | **不做任何 swizzle** —— 与已验证可用的同类插件（GaodeClean）形态一致 |
| 5 | **非 busy-loop** —— 15 秒 tick + 退避 1→30 秒 + 20 秒冷却 + 同链路只发一轮 |
| 6 | 只在 `com.apple.springboard` 宿主起蓝牙引擎，其它宿主只留信标 |

### 顺带的安全/隐私事实

- 解锁协议**完全离线**，不联网、不用 token
- 不采集、不上传任何数据
- 车辆 UUID / 车名仅从本机官方 App 容器读取

---

## 11. 版本演进史（每轮抓到的真 Bug）

从 1.0.0 到 1.1.2 共 **12 个版本**，每一版都是**抓到一个真 Bug** 才前进的：

| 版本 | 提交 | 抓到的问题 | 修法 |
|---|---|---|---|
| 1.0.0 | — | 手搓 clang + 自建 DEB 首版 | — |
| 1.0.1 | — | 注入没发生（日志 0 字节）| 过滤器加厚（Bundles + Executables）|
| 1.0.2 | — | 仍不注入 | 加对照组（注入「设置」）+ 多路径日志 |
| 1.0.3 | `0f95a1d` | `.xm` 在 CI 报 `const void*` 转换错 | 改 `.x`（ObjC）+ 显式转换 |
| 1.0.4 | `dc55b02` | **`SPLog` 用 C 的 `vsnprintf` → `%@` 退化**，吞掉异常真身 | 改用 ObjC 格式化 + 输出完整调用栈 |
| 1.0.5 | `25ebed4` | `CBCentralManagerOptionRestoreIdentifierKey` 在 SpringBoard 抛 `NSInternalInconsistencyException` | 去掉该选项 |
| 1.0.6 | `1684afe` | ① `SPUnlocker` 是块内局部变量 → **delegate(weak) 变 nil，回调永不触发**<br>② `SPTick` 在 `!armed` 时提前 return → **循环只跑一次**<br>③ 扫描仅限 FFF0（从未验证）| 静态强持有 + 先续期再干活 + 全设备扫描双匹配 |
| 1.0.7 | `7a4cd87` | （加探针）暴露「车辆 UUID 三个来源全空」 | 加 UUID 来源探针 + retrieve 打点 |
| 1.0.8 | `e982e62` | **UUID 读法错了** —— App 用 `standardUserDefaults`（App 容器），不是 suite | 改 cfprefsd `AnyUser` + 扫文件系统 |
| 1.0.9 | `cdd313a` | 包名 `huayuarc` 属**错误归属**（用户指出）| 改为 `com.jibamao.spsundiro` + `Replaces/Conflicts` |
| 1.1.0 | `c56daa7` | 两个诊断盲区：fff1 订阅无确认回调、无心跳 | 补 `didUpdateNotificationStateForCharacteristic` + 心跳 ⇒ **当轮真机成功** |
| 1.1.1 | `2628132` | **A1** `_doneLink` 死守卫（只读、从未赋值）→ 每 30 秒重发四帧<br>**A2** 特征回调 1 秒内被调 4 次刷屏 | `_doneLink = _linkAt` + `if (_wr && _nt) return` |
| **1.1.2** | `7cd495e` | **A3** `retryLater` 退避是 `static`，只增不减、无重置点 → 封顶后**永远 30 秒** | 改实例变量 `_backoff`，`start` 初值 + `didConnect` 复位 |
| 1.1.3 | `eed641d` | Sileo 详情框压平换行 → Debian 分段符 `.` 暴露成文本 | 改单段、标点断句 |
| 1.1.4 | `e300301` | **P1** 扫描冷却被 1.0.7 改成 20 秒未改回（占空比 83%）| 恢复 60 秒（占空比 → 42%）|
| **1.1.5** | `21ff82c` | 定版：去掉注入对照组；README/CHANGELOG/LICENSE 整理 | 代码逻辑零改动 |
| 1.1.6 | `b27a06b` | README 验证样例带入本机标识（车辆 UUID、车名）| 全面脱敏为占位符；去注入对照组；代码零改动 |
| 1.2.0 | `3046368` | 10 项可靠性缺陷（看门狗只护第 1 帧 / 无写回执 / 并发队列 / 守卫非原子 / 墙钟计时 / 6 路径日志…）| 逐项修复，**协议路径零改动**；真机 24 次解锁验证通过 |
| 1.2.1 | `a898a79` | 冷却锚点 `_lastAt` 跨链路存活 →「按一次不开、要按两次」 | 断开即作废锚点；真机 19s/20s 最窄考场通过 |
| 1.2.2 | `25c794a` | 蓝牙关闭丢回调 → `_connecting` 守卫永久卡死（356 秒零日志）| 状态变化复位守卫 + 静默 return 补限流日志 |
| 1.2.3 | `9ca52c2` | 守卫哨兵不区分「健康挂起 / 卡死」→ 48 条/小时噪声（1.2.2 自引入）| 按 `_car.state` 分档限流，噪声降至 6 条/小时；25.9h 长跑 98/98 零秒直发 |

### 几个通用教训（可复用）

1. **`CBCentralManager.delegate` 是 weak** —— 实例必须被强持有
2. **`vsnprintf` 不认识 `%@`** —— ObjC 项目日志一律用 `initWithFormat:arguments:`
3. **iOS 蓝牙权限按 bundle 隔离** —— 但 SpringBoard 天然拥有（实测 `蓝牙状态 = 5`）
4. **`cmp`/布尔比对，永远不要看打印出来的十六进制**（隐私模式会改写十六进制串）
5. **清 `/tmp` 前必须扫 `.git`** 查未推送提交（另一条平行经验）
6. **包名前缀要先确认作者身份**，不要沿用自己以前随手起的名字

---

## 12. 真机验收数据

测试设备：iPhone15,2 / iOS 16.2 / **Dopamine-roothide 真越狱** / SpringBoard 注入

### 12.1 完整成功链路（2026-10-10 08:48–08:59）

```
08:48:22 [link] 连接请求 -> SDH-xxxxxx
08:48:22 [link] ✅ 已连接 SDH-xxxxxx (累计 1 次)
08:48:22 [gatt] 服务 1800 / 1801 / FFF0 / D0FF / 180A / 1812
08:48:22 [gatt] 订阅 FFF1（车的回帧从这条来）
08:48:22 [gatt] 写特征 FFF6 就绪 → 立刻直发
08:48:22 [direct] -> 解锁帧 1/4（配对 #0）
08:48:22 [gatt] FFF1 订阅已生效（isNotifying=1）
08:48:23 [car] ← 车回帧 FFF1 len=26
08:48:23 [direct] -> 解锁帧 2/4
08:48:23 [car] ← 车回帧 FFF1 len=42
08:48:23 [direct] -> 解锁帧 3/4
08:48:24 [car] ← 车回帧 FFF1 len=26
08:48:24 [direct] -> 解锁帧 4/4
08:48:24 [direct] ★ 四帧发完 —— 耗时 1669 ms（累计成功 1 次）
```

### 12.2 关键指标

| 指标 | 实测值 | 对照 |
|---|---|---|
| **pending connect 存活** | **6 小时 26 分**（02:02 → 08:28）| 期间 169 条心跳，零人工干预 |
| **解锁握手耗时** | **1669 ~ 2297 ms** | 官方 App 版 2116 ms，**几乎一致** |
| **车回帧序列** | 26 → 42 → 26 字节 | 与官方协议**逐字节同构** |
| 连接→解锁延迟 | < 2 秒 | 车一出现立刻连、连上立刻发帧 |

### 12.2b A3 真机验证（2026-10-10 15:35）

```
15:35:56 ✅ 已连接 SDH-xxxxxx (累计 1 次)
15:35:58 ★ 四帧发完 —— 耗时 1347 ms
15:36:17 ⚠️ 断开：The connection has timed out unexpectedly.
15:36:17 断开 → 1 秒后重试                    ← ★ 退避复位到 1
15:36:18 ✅ 已连接 SDH-xxxxxx (累计 2 次)      ← ★ 1 秒后真连上
15:36:20 ★ 四帧发完 —— 耗时 1256 ms
```

同一段日志里，**1.1.1（A3 未修）** 的表现是：`08:58:23 1 秒` → `08:59:18 2 秒`（中间成功连接过，退避照样翻倍）。

### 12.3 各修复的真机验证数据

| 修复 | 修前 | 修后 |
|---|---|---|
| **A1**（重复发帧）| 1.1.0：8 分钟 **17 次**（每 30 秒准点）| 1.1.1：**1 次**，2 分 21 秒无重发；「2 次连接 ↔ 2 次解锁」严格 1:1 |
| **A2**（刷屏）| 1.1.0：`订阅 FFF1`/`写特征就绪` 各 **4 次** | 1.1.1：各 **1 次** |
| **A3**（退避）| 1.1.1：08:58:23 `1 秒` → 08:59:18 `2 秒`（中间成功连接过仍未复位）| 1.1.4：**`1 秒`** ✅ 且 1 秒后真连上（`累计 2 次`）|

---

## 13. 已知限制与待办

### 13.1 与官方 App 抢链路（**部分缓解** — 见 §16.2 D2 / §16.3 B2）

> 1.2.0 已消除**同秒双发 connect**（自家诱因），但"两个 central 争同一辆车"本质未变。

插件的连接请求和官方 App 会竞争同一辆车。建议**用前把官方 App 从后台划掉**。

> 可选的「让位逻辑」（检测到 App 在跑就暂避）已提过，**用户未选择**，暂不实现。

### 13.2 `Failed to encrypt the connection`（**成因部分定位** — 见 §16.2 D2）

> 1.2.0 已确认一条**自家来源**：同秒双发 connect 会让握手更易撞车。弱信号这条仍未排除。

实测出现 4 次，典型形态：

```
08:41:45 连接失败：Failed to encrypt the connection, the connection has timed out unexpectedly.
08:46:49 连接失败：同上
08:47:37 ✅ 已连接 (累计 2 次)          ← 随后能自动连上
```

| 可能成因 | 依据 |
|---|---|
| 蓝牙信号弱 | 该错误在**官方 App 版日志里也出现过**，当时归因于此 |
| 官方 App 抢链路 | 另一个 central 同时也连着车时的典型症状 |

**两者无法从日志区分** —— 无证据不猜，暂不修。

### 13.3 掉线间隔差异大（**成因未定**）

```
08:58:23 断开（连了约 10 分钟）
08:59:18 断开（连上仅 18 秒）
```

原因不明，可能与车的休眠策略 / 信号 / 抢链路都有关。

### 13.4 其他

- **两个架构不可同时安装**（arm64e / arm64）
- ~~`com.apple.Preferences` 对照组注入上线后可删~~ → 1.1.6 起已删除
- ~~A3 复位效果待确认~~ → **已于 2026-10-10 15:36 真机验证通过**
- ~~1.2.x 真机验收~~ → 截至 2026-10-13 已累计 25.9h / 12 会话 / 98 次零秒直发（第 5/6 轮判读报告见 `docs/`）

---

## 14. 构建与发布流程

### 14.1 CI（GitHub Actions）

- 工作流：`.github/workflows/build.yml`，名称 **`Build SundiroSPUnlock`**
- 环境：`macos-14` + `roothide/theos`
- 一次构建**两个 scheme**：rootless `arm64` 与 roothide `arm64e`
- 触发：推送 `main`

### 14.2 本地源码级验证（改代码后必做）

```bash
cd /tmp/sproot/SundiroSPUnlock

# ① 转成可独立编译的形式（%ctor → constructor）
python3 -c "
import io
s=io.open('Tweak.x',encoding='utf-8').read()
s=s.replace('%ctor {','__attribute__((constructor)) static void SPEntry(void) {')
io.open('/tmp/sproot/check.m','w',encoding='utf-8').write(s)
"

# ② ObjC 与 ObjC++ 各编一遍（CI 上是 ObjC，双验更保险）
for lang in "" "-x objective-c++"; do
  clang -target arm64e-apple-ios15.0 -isysroot /tmp/sdk165/iPhoneOS16.5.sdk \
    -fobjc-arc -fblocks -fobjc-runtime=ios-15 -O1 -c $lang -I/tmp/sproot /tmp/sproot/check.m \
    -o /tmp/sproot/chk/x.o && echo "  ✓ 通过 ${lang:-(ObjC)}"
done
```

### 14.3 发布清单（**逐项必查**）

1. 改 `Tweak.x` 的 `SPVER` 与 `control` 的 `Version`
2. 本地双编译通过
3. 推 `main`，等 CI 双 scheme 全绿
4. 下载产物，`dpkg-deb -f` 核对 **Package / Version / Architecture**
5. 从 dylib 里 `strings` 核验版本字符串
6. 核验载荷路径：arm64e → `Library/...`；arm64 → `var/jb/Library/...`
7. 生成源码 ZIP（排除 `.theos/`、`packages/`、`.git/`、`.deb`）
8. 生成 `SHA256SUMS`
9. 上传 Release 资产（用 `releases/assets` 原始二进制上传）
10. **回下载核 sha256**（不只信 HTTP 200）

---

## 15. 排障速查表

### 15.1 日志判读

| 日志 | 含义 | 下一步 |
|---|---|---|
| `蓝牙状态 = 5 (已开启)` | SpringBoard 蓝牙权限正常 | — |
| `蓝牙状态 = 3` | **未授权** → 路线不可行 | 检查系统蓝牙授权 |
| `扫描命中 sb.vehicle ← ...` | 从 App 容器读到了 UUID | — |
| `★ 所有来源都没读到车辆 UUID` / `App 容器里也没找到` | App 从未连过车 | 先打开一次官方 App 连上车 |
| `retrieve 已知 UUID 命中 1 个外设` | 系统认识这辆车 | — |
| `连接请求 -> SDH-xxxxxx` | pending connect 已挂出 | 等车出现 |
| `心跳 外设状态=1` | Connecting（等车）| 正常待机 |
| `心跳 外设状态=2` | **Connected** | 正常 |
| `✅ 已连接` | 连上了 | — |
| `FFF1 订阅已生效` | **回帧通道打通** | — |
| `写特征 FFF6 就绪 → 立刻直发` | 开始握手 | — |
| `★ 四帧发完` | **解锁成功** | — |
| `第 1 帧后 3 秒无车回帧，放弃本轮` | FFF1 订阅没生效 / 车没应答 | 查上一行的订阅状态 |
| `断开 → N 秒后重试` | 重连中 | **N 应为 1**（A3 门禁）|

### 15.2 验收门禁（回归测试标准）

| 检查项 | 合格标准 |
|---|---|
| **A1** 重复发帧 | 每次 `✅ 已连接` 后，`★ 四帧发完` **只应出现 1 次** |
| **A2** 日志刷屏 | `订阅 FFF1` / `写特征 FFF6 就绪` 每次连接**各 1 次** |
| **A3** 退避复位 | `✅ 已连接` 之后出现的 `→ N 秒后重试`，**N 必须从 1 开始** |
| **基本功能** | 走到车旁 → 自动连接 → 四帧发完 → 车解锁 |

### 15.3 常用命令

```bash
# 看日志
cat /var/mobile/Library/Logs/sundirosp.log

# 重启桌面（装完插件后）
killall -9 SpringBoard

# 立即停用
touch /var/mobile/Library/Preferences/com.jibamao.spsundiro.off && killall -9 SpringBoard

# 恢复
rm /var/mobile/Library/Preferences/com.jibamao.spsundiro.off

# 确认插件已加载
# 看 SpringBoard 已加载模块表里是否有 SundiroSPUnlock.dylib
```

### 15.4 装不上 / 不生效排查顺序

1. **架构对不对** —— RootHide 用 arm64e，rootless 用 arm64
2. **插件加载了没** —— 查 SpringBoard 模块表
3. **日志有没有** —— 看 `[boot]` 那两行
4. **宿主对不对** —— 必须是 `bundle=com.apple.springboard`
5. **kill-switch 存在吗** —— 存在则什么都不跑

---

## 附：关键标识符速查

| 项 | 值 |
|---|---|
| 包名 | `com.jibamao.spsundiro` |
| 偏好域 | `com.jibamao.spsundiro` |
| 日志（默认） | `/var/mobile/Library/Logs/sundirosp.log` |
| 日志路径配置 | `/var/mobile/Library/Preferences/com.jibamao.spsundiro.logpath` |
| kill-switch | `/var/mobile/Library/Preferences/com.jibamao.spsundiro.off` |
| 目标服务 | `0000FFF0-0000-1000-8000-00805F9B34FB` |
| 写特征 / 通知特征 | `FFF6` / `FFF1` |
| 官方 App bundle | `com.sundirohonda.app` |
| 官方 App Group | `group.com.carbit.edrive.honda` |
| 车名前缀 | `SDH-` |
| 车辆 UUID（本机实测） | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| 车名（本机实测） | `SDH-xxxxxx` |
| 源码工程 | `/tmp/sproot/SundiroSPUnlock/` |
| SDK | `/tmp/sdk165/iPhoneOS16.5.sdk` |


---

## 16. 1.2.0 全面审计与修复（2026-10-10）

> **审计方法**：源码 694 行逐函数通读 × 真机日志 1800 行（2026-10-10 00:18 → 17:30，17 次装载）
> 双向对撞 —— 把源码里 17 个 `SPLog` 埋点逐个查日志出现次数，再按"连接区间"建表核对
> 订阅 / 帧1 / 完成 的计数是否自洽。**对不上的地方就是 bug 的藏身处。**

### 16.1 审计基线数据（1.1.6 真机实测）

```
连接请求 57  =  成功 45  +  失败 12        ← 账目完全平
订阅 44 / 就绪 44                          ← 一一对应
帧1 发起 54  =  完成 51  +  被打断 3        ← 3 次全在 1.1.4 窗口
四帧耗时 51 次：min 1149 / median 2296 / max 5938 ms
v1.1.6 段 14 次解锁：min 1970 / median 2693 / max 5640 ms，成功率 100%
```

**逐帧间隔上限**（决定看门狗阈值，为 1.2.0 的 A1 提供数据）：

| 区间 | 最大间隔 | 观测分布 |
|:--|:--|:--|
| `f1 → f2` | **3 秒** | 0,1,2,3 |
| `f2 → f3` | 2 秒 | 0,1,2 |
| `f3 → f4` | 1 秒 | 0,1 |

### 16.2 十二项缺陷清单

| # | 缺陷 | 等级 | 铁证 | 1.2.0 |
|:--|:--|:--|:--|:--|
| D1 | 注释声明"串行队列"，实际 `dispatch_get_global_queue`（并发），共享状态无锁 | 中 | 源码第 12 行 vs 358 行 | **B1 已修** |
| D2 | `tryConnect` 守卫非原子，可同秒双发 `connectPeripheral` | 中 | 日志 `16:52:40` 同秒两条连接请求，紧接 `16:52:44 Failed to encrypt` | **B2 已修** |
| D3 | 只有第 1 帧有看门狗，2/3/4 帧无超时 → 卡死即永久停摆 | 中 | 三条恢复路径全被堵死；唯一复位点是断线 | **A1 已修** |
| D4 | `didWriteValueForCharacteristic` 完全缺失 | 中 | 源码 0 处，而四帧全用 `WithResponse` | **A2 已修** |
| D5 | 日志每行写 6 个文件，轮转只覆盖 1 个 | 低-中 | 第 361–365 行 vs 372–379 行 | **D1 已修** |
| D6 | 非 SpringBoard 宿主仍启动永久 15 秒定时器 | 低 | `%ctor` 无条件调 `SPTick` | **D2 已修** |
| D7 | 冷却在尝试开始就置位，失败不回滚 | 低 | 第 443 行 | **随 A1/A2 已修** |
| D8 | 车回帧仅按长度匹配，不校验是否本轮应答 | 低 | `len=26` 出现 174 次，静置期也在发 | **明确不改**（见 16.4） |
| D9 | kill-switch / logpath 未做 RootHide 动态 jbroot 适配 | 中 | 与 RootHide 铁律冲突；且 `return` 在日志初始化之前 → 无法验证 | **C1 已修** |
| D10 | 第 1 帧看门狗 3.0 秒**零余量** | 中 | 实测最慢 `f1→f2` 正好 3.0 秒 | **A1 已修**（8 秒） |
| D11 | `SPKnownVehicleUUID()` 无缓存，`_car` 为 nil 时每 15 秒全目录扫描 | 低-中 | 第 399 行无 `_carUUID.length` 前置判断 | **C2 已修** |
| D12 | 全部计时用墙钟，回拨会让冷却/扫描锁死 | 低 | 7 处 `NSDate.timeIntervalSince1970` | **C3 已修** |
| — | 死代码 `kSvcFFF0` / `kAppPrefs` / `lastCarFrame` | 卫生 | 三处"定义即唯一出现" | **D3 已修** |

**D12 的门禁价值（实录）**：第一轮替换只找到 6 处，门禁脚本扫出**第 7 处**
（`didDiscoverPeripheral` 里给"旁侧设备"日志节流的 `static NSTimeInterval lastLog`）。
若没有这道自动化门禁，这一处必然漏改。

### 16.3 1.2.0 修复要点

- **A1 每步看门狗**：`_round` 轮次号做代际校验（旧定时器不会误杀新轮次）+ 有界自愈
  （同链路最多立即重发 2 次，防死循环）+ 失败即清 `_lastAt`（不让失败吃掉 20 秒窗口）。
  阈值取 **8 秒** = 实测最大间隔 3 秒的 2.6 倍余量。
- **B1 专用串行队列**：`SPQueue()`，6 处调用点统一。这样 A1 的 `_round`/`_step` 校验才真正原子。
- **C1 多根探测**：`SPRoots()` 枚举 真实根 / `/var/jb` / 全部 `.jbroot-*`；
  `SPFind()` 返回第一个真实存在的路径。安全阀命中时**写日志留痕**，从此可验证。

### 16.4 明确不改：车回帧仅按长度匹配（D8）

车回帧的判定是 `(L == 26 || L == 42)`，属**故意宽松**、继承自**已量产**的官方 App。
收紧它（改为严格 `26 → 42 → 26` 序列）只能**降低**解锁成功率；而且静置期车端周期性发出的
`len=26`（日志中 174 次）与"第 1 帧应答"**长度完全相同**，在握手窗口内**无法区分**。
**无安全修法，改动风险 > 收益，保持原样。** 已用 1.1.6 的 51 组成功序列验证该假设成立。

> **推论（需知晓）**：日志里的"★ 四帧发完 —— 累计成功 N 次"是**自述式成功**，
> 并非车端确认。极低概率下若静置帧恰好插进握手窗口，可能出现"握手完整但车未开"。
> 该风险与官方 App 同源，非本项目引入。

### 16.5 协议路径零改动（可独立验证）

`kUnlockConst32`、49 组 `kUnlockPairs`（共 **1568** 字节）、`SPFrame()`、
`onCarFrame` 的四步推进条件与发出的帧内容 —— **逐字节未动**。

**验证方式**（已执行通过）：
```sh
# 从源码提取 1568 字节配对表，在三份二进制里搜索
#   1.1.6 CI 产物 → 命中
#   1.2.0 CI 产物 arm64 → 命中
#   1.2.0 CI 产物 arm64e → 命中
```

### 16.6 1.2.0 构建与验收记录

| 项 | 结果 |
|:--|:--|
| 提交 | `3046368` |
| CI run | `38043578178`（Theos 双 scheme）**success** |
| Release | `v1.2.0`，id `408860839`，4 资产回下载**逐字节一致** |
| arm64 deb | `com.jibamao.spsundiro_1.2.0_iphoneos-arm64.deb` sha `8730b9fc70cd62f6…` |
| arm64e deb | `com.jibamao.spsundiro_1.2.0_iphoneos-arm64e.deb` sha `cb28a714d451d700…` |
| 源码包 | `SundiroSPUnlock-1.2.0-Source.zip` sha `8cf51bbc3aa1785b…` |
| 载荷路径 | arm64 → `/var/jb/Library/MobileSubstrate/DynamicLibraries/`；arm64e → `/Library/MobileSubstrate/DynamicLibraries/` |
| 维护脚本 | 无（`DEBIAN` 仅 `control`/`md5sums`）→ 无路径转换风险 |
| dylib | 203168 字节（1.1.6 为 202928，+240），胖二进制 arm64+arm64e |
| 二进制核验 | `dispatch_get_global_queue` **已彻底消失**；新增 `clock_gettime`、`dispatch_queue_create` |
| 本地门禁 | 双架构编译零警告；协议数据段 sha256 与 1.1.6 一致 |

### 16.7 ★ 真机验收门禁（装 1.2.0 后必查）

| # | 判据 | 通过标准 |
|:--|:--|:--|
| 1 | **解锁耗时不得退化** | 中位数 ≤ **2693 ms**；无一次 > **7000 ms** |
| 2 | 解锁成功率 | 连续 ≥30 次接近 100% |
| 3 | 断开重挂 | 全部 `断开 → 1 秒后重试` |
| 4 | A1 看门狗 | `★ 第 N 帧后 8 秒无车回帧` 出现次数应为 **0**；若出现，必须紧跟 `★ 链路仍在 —— 立即重发` 且最终解锁成功 |
| 5 | B2 守卫 | 日志**永不出现**同秒双发 `连接请求` |
| 6 | A2 写回调 | 若出现 `★ 写 FFF6 失败`，下一次心跳 `步=0`（不再卡住） |
| 7 | 心跳 | `步=` 始终为 0 |
| 8 | C1 安全阀 | 创建 `.off` → 注销 → 日志出现 `★ kill-switch 命中（<路径>）—— 不启动蓝牙`；删除后恢复 |
| 9 | 稳定性 | ≥2 小时无 SpringBoard 异常 |

**回滚**：1.1.6 的 deb 保留在 `definitive-1.1.6/`，任一门禁不过立即回退。

---

## 17. 1.2.1 → 1.2.3 验收纪要（2026-10-13 复核）

| 版本 | 判读轮次 | 关键结论 |
|:--|:--|:--|
| 1.2.1 | 第 3 轮（10-11） | 真机首考「冷却锚点随链路作废」通过：Δ=16s < 20s 冷却线当场直发 |
| 1.2.3 | 第 5 轮（10-12） | **8 秒看门狗真机首触 + 自愈成功**；A1 最窄考场（19s < 20s）通过 |
| 1.2.3 | 第 6 轮（10-13） | **25.9 小时 / 12 会话长跑**：98/98 零秒直发、自愈 4/4、零缺陷零施工项 |

**累计数据基线（1.2.3 段）**：四帧耗时 min 1313 / 中位 2847 / max 7275 ms；
挂起日志噪声 5.1 条/小时；冷却误挡 0、双发 0、卡死告警 0。

> 完整判读报告：`docs/SundiroSPUnlock-1.2.3-判读报告-第5轮-2026-10-12.md`、
> `docs/SundiroSPUnlock-1.2.3-判读报告-第6轮-2026-10-13.md`
