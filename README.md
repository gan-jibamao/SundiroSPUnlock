# SundiroSPUnlock

> 新大洲本田蓝牙无感解锁 —— 独立成 SpringBoard 插件，不依赖官方 App。

[![Build](https://github.com/gan-jibamao/SundiroSPUnlock/actions/workflows/build.yml/badge.svg)](https://github.com/gan-jibamao/SundiroSPUnlock/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/gan-jibamao/SundiroSPUnlock?label=release)](https://github.com/gan-jibamao/SundiroSPUnlock/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**当前版本 `1.3.10`** · 支持 `iphoneos-arm64e`（RootHide）与 `iphoneos-arm64`（rootless）

拿着手机靠近车辆，**按车辆解锁键，一秒解锁**。
车况遥测、小组件、深链控制仍由官方 App 负责，两者互不干扰。

---

## 为什么能脱离官方 App

解锁协议**完全自包含**，全部来自官方 App 的实测采集：

| 依赖项 | 来源 |
|:--|:--|
| 4 帧协议报文 | 离线造帧（XOR 校验 + `AA AA` 尾） |
| 49 组 `(R, R3)` 配对 | 硬编码常量表 |
| 32 字节常量 | 硬编码 |
| 服务 / 特征 UUID | `FFF0 / FFF1 / FFF6` |
| 网络 / token / 官方 App | **完全不需要** |

### 核心机制：抢一个「永不被挂起」的位置

iOS 会无限期保持一个**挂起的蓝牙连接**（pending connect）—— 实测存活 **6 小时 26 分**，
期间零人工干预，车一出现即自动连上。

官方 App 也能挂这个连接，**但它会被 iOS 挂起**。
**SpringBoard 永远不会被挂起** —— 这就是本项目存在的理由。

---

## 当前状态 · `1.3.10`（2026-11-09）

### 实机验收

对比环境：同一台车、同一部手机，1.3.9 → 1.3.10 连续两个版本的真机日志。

| 指标 | 1.3.9 | **1.3.10** | 变化 |
|:--|--:|--:|--:|
| **车可见期间在线率** | 12.4% | **57.4%** | **4.6 倍** |
| 订阅成功率 | 13.1%（8/61） | **100%**（4/4） | — |
| 连接（次/小时） | 5.45 | **0.41** | ↓92.4% |
| 断开（次/小时） | 7.85 | **1.03** | ↓86.8% |
| 加密失败（次/小时） | 2.02 | **0.10** | ↓94.9% |
| 僵尸 pending（次/小时） | 2.40 | **0.62** | ↓74.2% |

解锁握手耗时 **1205 / 1244 / 1270 / 1898 ms** —— 与 1.3.9 持平，无退化。

### 1.3.10 修了什么

两个**永远不会被执行**的分支：

**C · 僵尸 pending 取消后不重新扫描**

`retryLater` 的 zombie 分支只做 cancel + 重连，没有 `beginScan`。
而 A5（车在广播就立刻重连）的触发源是 `didDiscoverPeripheral` ——
不扫描 ⇒ 车广播也不回调 ⇒ A5 永不触发。

> 1.3.9 实测：83 次僵尸回收，其后 8 行内出现「开始扫描」**0 次**。

修法补 `stopScan` + `beginScan`。**必须先 stopScan**，因为 `beginScan` 首行是
`if (… || _scanning) return;`，标志卡住时静默返回、一行日志都不打。

**D · 长挂起兜底条件恒假**

```objc
if (held > 180.0 && _car.state != CBPeripheralStateConnecting) { ... }
```

挂起时 `state` 恒为 `Connecting`(1)，条件永远为假 ⇒ 3 分钟兜底一次都没执行。
三天日志 240 条「已挂 > 600 秒」，最长 **21542 秒（5.98 小时）**，
而「连接卡死」日志出现 **0 次**。

改为**条件化**：车可见（120 秒内扫到过）才判卡死并重连；车睡着时保留 pending 安静等待。
（直接改成 `!= Connected` 会让车睡着时每 3 分钟白折腾一次。）

### 演进要点

| 版本 | 关键改动 |
|:--|:--|
| 1.2.6 | GATT 只发现 FFF0 + 只问 FFF1/FFF6，就绪 3.0s → 0s |
| 1.2.7 / 1.2.8 | 按键帧「字节直认」触发，取代定时器补发 |
| 1.2.10 | 撤销 1.2.9 的「8 秒取消」（误诊），连接 churn 降 500 倍 |
| 1.2.11 | 修 `_fullDiscovery` 被一次慢回包永久降级；修日志乱码 |
| 1.2.13 | 常驻扫描 + 强制刷新连接（车认到后不再永久停扫） |
| 1.2.14 | 修「名字前缀认错车」（现场有两台 SDH- 车）；扫描占空比 29% → 100% |
| 1.3.0 | 连接与解锁解耦：连接常挂，解锁只在按键 / 睡醒时触发 |
| 1.3.1 | 掉线 0.15 秒即刻重连（可用率 5.9% → 55.3%）|
| 1.3.2 | **C1：彻底取消自动解锁，只认按键帧** |
| 1.3.3 → 1.3.5 | 追「僵尸 pending」时引入 cancel 死循环，1.3.5 修正为「仅 >90 秒才 cancel」 |
| **1.3.10** | 僵尸取消后补 `stopScan`+`beginScan`；长挂起兜底条件化 |

> 每个版本的根因、铁证与逐项验收见 [CHANGELOG.md](CHANGELOG.md)。

---

## 安装

**从 Sileo 源安装（推荐）** —— 添加 `https://gan-jibamao.github.io/`，搜 `Sundiro`。

或到 [Releases](https://github.com/gan-jibamao/SundiroSPUnlock/releases/latest) 下载 deb：

| 包 | 适用 |
|:--|:--|
| `…_iphoneos-arm64e.deb` | **RootHide / Dopamine-roothide** |
| `…_iphoneos-arm64.deb` | Dopamine（传统 rootless） |

装完执行：

```sh
killall -9 SpringBoard
```

> ⚠️ 两个架构**不可同时安装**。
> ⚠️ 不要用 `dpkg -i` —— 那样会跳过 RootHide 的安装钩子。

---

## 验证

装好后到车附近，看日志：

```sh
cat /var/mobile/Library/Logs/sundirosp.log
```

**成功的解锁长这样**：

```
✅ 已连接 SDH-xxxxxx (累计 1 次)
服务 FFF0
订阅 FFF1（车的回帧从这条来）
写特征 FFF6 就绪 —— 请求直发
← 车回帧 FFF1 len=26
-> 解锁帧 1/4（配对 #0）… 4/4
★ 四帧发完（42 已确认）—— 耗时 1270 ms（累计成功 1 次）
```

### 日志标签

| 标签 | 含义 |
|:--|:--|
| `[boot]` | 启动 / 装载 / 蓝牙状态 |
| `[probe]` | 车辆 UUID / 车名读取 |
| `[link]` | 扫描 / 认车 / 连接 / 断开 / 重试 |
| `[gatt]` | 服务与特征发现 / FFF1 订阅状态 |
| `[direct]` | 四帧握手推进 |
| `[car]` | 车的回帧 |
| `[life]` | 每 2 分钟心跳 |

### 1.3.10 新增的自愈日志

| 日志 | 含义 |
|:--|:--|
| `停止扫描（僵尸取消后复位扫描标志）` | C 生效，标志已复位 |
| `开始扫描（僵尸取消后重扫）` | C 生效，A5 恢复感知 |
| `连接挂起 N 秒 —— 车已 M 秒不可见，继续等车广播` | D 生效，车睡着时安静等待 |
| `★ 连接卡死 N 秒（… 车可见 M 秒前）` | D 生效，车可见但连不上，已重连 |

### 心跳怎么读

| 字段 | 含义 |
|:--|:--|
| `外设状态=1` | Connecting（正在等车） |
| `外设状态=2` | Connected（已连上） |
| `已连=N` / `已解锁=M` | 累计连接 / 累计成功解锁，应 1:1 |

> **找不到日志？** 插件同时写 `NSLog`，并内置 5 个候选路径
> （`Preferences/`、`Documents/`、`/var/jb/var/mobile/Library/Logs/`、`/tmp/`、`/var/tmp/`）。

---

## 控制

| 动作 | 命令 |
|:--|:--|
| 立即停用 | `touch /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` 后 `killall -9 SpringBoard` |
| 恢复 | `rm /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` |
| 只关解锁（保持连接） | 偏好域 `com.jibamao.spsundiro` 写 `unlock = NO` |
| 卸载 | Sileo 卸载，或删 `DynamicLibraries/SundiroSPUnlock.{dylib,plist}` |

> kill-switch 会同时探测**真实根 / `/var/jb`（rootless）/ 全部 `.jbroot-*`（RootHide）**，
> 所以无论用哪种工具创建都能被认到。命中时日志留一行
> `★ kill-switch 命中（<路径>）—— 不启动蓝牙`。

---

## 构建

由 GitHub Actions 构建，见 [`.github/workflows/build.yml`](.github/workflows/build.yml)。

```sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

### ⚠️ 两个必须注意的坑

**1 · 必须用 `macos-15`**

`macos-14` 已于 **2026-11-02** 从 GitHub Actions 退役。用它会 1 秒 `cancelled`
（`runner_id=0`、`runner_name` 为空），而 GitHub 状态页显示一切正常 —— 因为是计划内退役。

**2 · Xcode 必须降到 16.0**

`macos-15` runner 默认 Xcode 16.4。**16.4 生成的 objc 元数据在 iOS 16.2 上加载即崩**：
SpringBoard 启动 7 毫秒死在 `objc readClass`（SIGBUS @ `0xdac11a30`），连崩 3 次后进安全模式。

```yaml
- run: sudo xcode-select -s /Applications/Xcode_16.0.app
- run: brew install ldid
```

判据（与 1.3.9 基准逐节比对）：

| 节 | Xcode 16.0 | Xcode 16.4 |
|:--|--:|--:|
| `__objc_methlist` | **1460** | 2036 ✗ |
| `__objc_const` | **4144** | 3072 ✗ |
| `__objc_selrefs` | **1472** | 1728 ✗ |

**编译成功 ≠ 能加载。** 换任何工具链都要做这一步比对。

---

## 安全设计

SpringBoard 崩 = 注销，开机崩 = 白苹果循环，所以：

1. **kill-switch 是第一件事** —— 文件存在就直接 return，绝不碰蓝牙
2. 全部逻辑在后台串行队列，**不阻塞启动路径**
3. 逐层 `@try/@catch`，异常绝不外泄
4. **不做任何 swizzle**（纯新增行为，不改系统实现）
5. 非 busy-loop —— 15 秒 tick + 退避（连上即复位）+ 解锁冷却 20 秒 + 同链路只发一轮

过滤器：

```xml
Filter = { Bundles = [com.apple.springboard], Executables = [SpringBoard] }
```

---

## 已知限制

- **会与官方 App 抢链路** —— 建议用前把官方 App 从后台划掉
- 车端 BLE 在部分时段**停止广播**（实测连续 16~32 分钟完全扫不到），手机侧无解
- 车在 30 米外穿墙时 RSSI 中位 **-90 ~ -94**，处于连接临界点，可用率随距离剧烈波动
- `Failed to encrypt the connection` 为 iOS 链路层配对失败，多为**车端被其他主设备占用**，非插件可控
- 车回帧仅按长度匹配（26 / 42）—— 继承官方 App 的宽松匹配，收紧只会降低成功率
- 从未扫到过车时日志显示「车已 1000000000 秒不可见」（=从未见过），逻辑正确、可读性待改

---

## 文档

| 文档 | 内容 |
|:--|:--|
| [CHANGELOG.md](CHANGELOG.md) | 逐版本根因、铁证、验收数据 |
| [docs/](docs/) | 真机验收判读报告、技术文档 |

---

## 许可证

[MIT](LICENSE)
