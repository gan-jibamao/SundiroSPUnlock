# 更新日志

本项目所有重要改动均记录于此。版本号遵循 `主.次.修订`。

> 使用与安装说明见 [README.md](README.md)。

---

## [1.2.0] — 可靠性加固（10 项缺陷修复，**协议路径零改动**）

> **验收红线：解锁速度不得退化。** 1.1.6 真机实测四帧耗时中位数 **2693 ms**（1970–5938 ms），
> 1.2.0 必须 ≤ 该基线。所有新增逻辑只挂在**异常路径**上，正常解锁一次都不触发。

### 修复

| # | 缺陷 | 说明 |
|:--|:--|:--|
| **A1** | 只给第 1 帧设看门狗，2/3/4 帧**无任何超时** | 握手中途卡死会**永久停摆**（三条恢复路径全被堵死，唯一复位点是断线）。且原阈值 3.0 秒 vs 实测最慢 `f1→f2` 正好 3.0 秒 = **零余量**。现改为**每步 8 秒看门狗** + 轮次代际校验 + 有界自愈（≤2 次立即重发） |
| **A2** | `didWriteValueForCharacteristic` 完全缺失 | 四帧全部 `WithResponse` 写出却没有回执，写失败时 `_step` 既不推进也不回退。现已实现，失败即释放本轮 |
| **B1** | 注释声明"串行队列"，实际用 `dispatch_get_global_queue`（**并发**） | 共享状态无锁并发读写；最危险时 `_pick` 前进两次 → `R`/`R3` 配对错位 → 解锁失败。现改为**专用串行队列**，6 处调用点统一 |
| **B2** | `tryConnect` 守卫非原子 | 1.1.6 日志铁证：`16:52:40` 同秒双发 `连接请求`，紧接 `16:52:44 Failed to encrypt`。现加 `_connecting` 标志，三个调用点共用 |
| **C1** | kill-switch / logpath 未做 RootHide 动态 jbroot 适配 | 用带 vroot 的工具创建 `.off` 会落进隐根镜像 → 开关静默失效，且 1.1.6 的 `return` 在日志初始化之前，**连"检查过"都无法留痕**。现同时探测真实根 / `/var/jb` / 全部 `.jbroot-*`，命中即写日志 |
| **C2** | `SPKnownVehicleUUID()` 无缓存 | `_car` 为 nil 时 `SPTick` 每 15 秒重跑一次全目录扫描（约 200 次文件读）。现只读一次 |
| **C3** | 全部计时用墙钟 `NSDate.timeIntervalSince1970` | 时间被 NTP 或手动回拨会让冷却/扫描**锁死**。现改单调时钟（`CLOCK_MONOTONIC`），7 处统一 |
| **D1** | 日志每行写 **6 个**文件，轮转只覆盖其中 1 个 | 其余 5 个无界增长；且每行 6 次 `fopen/fwrite/fflush/fclose` 是**串在解锁关键路径上的 I/O**。现只写已探测出的单一可写路径，**关键路径 I/O 降低约 83%** |
| **D2** | 非 SpringBoard 宿主仍启动永久 15 秒定时器 | `SPTick` 移入 `start`，只有真起了蓝牙引擎才跑 |
| **D3** | 死代码 | `kSvcFFF0` / `kAppPrefs` / `lastCarFrame` 三处"定义即唯一出现" |

### 明确不改

**车回帧仍仅按长度匹配**（`26` / `42`）。该宽松匹配继承自**已量产的官方 App**；
收紧它只能降低解锁成功率，且静置期 `len=26` 广播在握手窗口内**无法与真应答区分**（长度完全相同）。
已用 1.1.6 的 51 组成功序列验证该假设成立 —— **无安全修法，保持原样**。

### 协议路径零改动（可独立验证）

`kUnlockConst32`、49 组 `kUnlockPairs`（共 1568 字节）、`SPFrame()`、
`onCarFrame` 的四步推进条件与发出的帧内容 —— **逐字节未动**。
1.2.0 构建产物中的该 1568 字节数据段与 1.1.6 **完全一致**。

---

## [1.1.6] — 定版（脱敏修正）

### 变更
- **披露修正**：1.1.5 的 README.md 里验证样例带入了本机标识（车辆 UUID、车名完整值），
  已替换为 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` / `SDH-xxxxxx`
- `Tweak.x` 里的注释同样脱敏（功能字符串 `"SDH-"` 前缀本身保持不变）
- **代码逻辑零改动**（仅注释/文档；编译产物与 1.1.5 一致）

### 说明
本项目的公开文件（README / CHANGELOG / 源码）不应包含任何本机标识：
车辆 UUID、车名完整值、VIN、设备号、App 容器路径。

---

## [1.1.5] — 定版

### 变更
- **去掉注入过滤器里的对照组** `com.apple.Preferences`（当初为排查注入链路而加，使命已完成）
- 补 `README.md`：更新验证样例、修复记录、心跳判读表、已知限制
- 新增 `LICENSE`（MIT）与 `CHANGELOG.md`
- 代码逻辑零改动

---

## [1.1.4] — P1：扫描省电

### 修复
- **P1**：扫描冷却由 20 秒恢复为 **60 秒**

### 详情
该 20 秒是 1.0.7 为加速实测临时改快、一直未改回。它只影响**「车 UUID 未知」**场景
（正常情况 `retrievePeripheralsWithIdentifiers` 一次命中，插件**从不扫描**）。

| 项 | 改前 | 改后 |
|:--|:--|:--|
| 扫描节奏 | 每 30 秒一轮、每轮扫 25 秒 | 每 60 秒一轮、每轮扫 25 秒 |
| **扫描占空比** | **83%** | **42%** |

---

## [1.1.3] — 详情文案

### 变更
- Sileo 的「详情」框会把换行**压成一个段落**，导致旧文案里 Debian 的分段符 `.` 暴露成文本
- 改为**单段、用标点断句**，不再依赖换行排版
- 仅改文案与版本号，代码逻辑零改动

---

## [1.1.2] — A3：重连退避复位

### 修复
- **A3**：`retryLater` 的退避曾是 `static` 局部变量，**只增不减、全工程无重置点** ——
  封顶 30 秒后即便之后连续成功几十次，下次断开仍要干等满 30 秒

### 详情
退避 1 → 2 → 4 → 8 → 16 → 30 → 30 → 30…（**封顶后永远 30 秒**）

改法（对照官方 App —— 其 `_backoff` 是实例变量并在 7 处主动重置）：

| 位置 | 改动 |
|:--|:--|
| 属性区 | 新增 `@property NSTimeInterval backoff;` |
| `start` | `_backoff = 1.0;`（**必须在建 `_cm` 之前** —— ivar 默认 0 会让 `MIN(0,30)=0` 秒，变成疯狂重连） |
| `didConnectPeripheral` | `_backoff = 1.0;` ★ 连上即复位 |
| `retryLater` | 去掉 `static`，改用 `_backoff` |

**真机验证**：断开后重试间隔回到 **1 秒**（未修版本会翻倍到 2 秒）。

---

## [1.1.1] — A1 / A2

### 修复
- **A1**：`_doneLink` 是**死守卫** —— 全工程只读、从未赋非零值，判重恒为假
  ⇒ 车已解锁仍每 ~30 秒重发一轮四帧（实测 8 分钟发了 **17 次**）
  → 第 4 帧完成后补 `_doneLink = _linkAt;`（断开时仍清零，下次靠近照样解锁）
- **A2**：`didDiscoverCharacteristicsForService` 1 秒内被回调 4 次刷屏
  → 特征已收全则直接 `return`

**真机验证**：同场景由 17 次降至 **1 次**；「2 次连接 ↔ 2 次解锁」严格 1:1。

---

## [1.1.0] — 诊断盲区

### 新增
- `didUpdateNotificationStateForCharacteristic` —— **FFF1 订阅是否真生效**的唯一凭据
  （车的回帧全靠这条通道）
- `SPTick` 心跳日志（每 2 分钟）—— 证明插件存活，并显示外设状态

### 结果
**当轮真机成功**：08:28:50 自动连接 → 服务 FFF0 → 订阅 FFF1 → 四帧握手 → **1996 ms 完成**。

---

## [1.0.9] — 包名前缀更正

### 变更
- 包名 / 偏好域 / kill-switch 前缀由 `huayuarc` 更正为 **`jibamao`**
  （`com.huayuarc.spsundiro` → **`com.jibamao.spsundiro`**）
- `Maintainer` / `Author` 同步更正
- 加 `Replaces:` + `Conflicts: com.huayuarc.spsundiro`，装新版自动顶掉旧包
- 删除废弃的 `kRestoreID` 常量

---

## [1.0.8] — 车辆 UUID 读取

### 修复
- **UUID 读法错了**：官方 App 用的是 `[NSUserDefaults standardUserDefaults]`
  （数据存在 **App 自己的容器**里），不是 suite。
  从 SpringBoard 用 `initWithSuiteName:` **读不到**。

### 详情
路径：`/var/mobile/Containers/Data/Application/<App-UUID>/Library/Preferences/com.sundirohonda.app.plist`

改用两条路：
1. `CFPreferencesCopyValue(…, kCFPreferencesAnyUser, kCFPreferencesAnyHost)` 跨用户域读
2. 直接扫文件系统（App 容器 + App Group）

读到的键：`sb.vehicle`（UUID）、`sb.vehicle.name`（车名）

---

## [1.0.7] — UUID 来源探针

### 新增
- 车辆 UUID 多来源探针 + `retrievePeripheralsWithIdentifiers` 命中数打点
- 作用：暴露「三个来源全空」这一事实，直接引出 1.0.8 的修复

---

## [1.0.6] — 三个致命 Bug

### 修复
- **① `SPUnlocker` 是块内局部变量** —— 而 `CBCentralManager.delegate` 是 **weak** 引用，
  块一结束实例就被 ARC 回收 → delegate 变 nil → `centralManagerDidUpdateState` **永不回调**
  → 改为 **静态强持有** `static SPUnlocker *gUnlocker`
- **② `SPTick` 在 `!armed` 时提前 return** → 循环只跑一次就断
  → 把「续期」挪到函数**最前面**（先续期、再干活）
- **③ 扫描仅限 FFF0 服务 UUID** —— 但车未必在广播里带它
  → 改为**全设备扫描** + 「已知 UUID / 名字前缀 `SDH-`」双重匹配

---

## [1.0.5] — 状态恢复异常

### 修复
- 去掉 `CBCentralManagerOptionRestoreIdentifierKey`
  —— iOS 只允许声明了 `bluetooth-central` 后台模式的 App 做状态恢复，
  SpringBoard 带上会抛 `NSInternalInconsistencyException`。
  SpringBoard 是常驻进程，**根本不需要**状态恢复。

**副产品结论**：异常只关于 restore identifier，说明**已通过蓝牙 TCC 检查**。

---

## [1.0.4] — 日志格式化

### 修复
- `SPLog` 曾用 C 的 `vsnprintf` —— **它不认识 `%@`**，会把 `%@` 退化成 `@`
  并让后续参数整体错位（实测导致 pid/uid 变乱码、异常内容整条丢失，日志只剩 `启动异常: @`）
- 改用 ObjC 格式化：`[[NSString alloc] initWithFormat:fmt arguments:ap]`，并输出完整调用栈

---

## [1.0.3] — Theos 官方流程首版

### 修复
- `.xm`（ObjC++）在 CI 编译器下报 `const void*` → `const unsigned char*` 隐式转换错
- 改为 `.x`（ObjC）+ 显式转换

---

## [1.0.2] / [1.0.1] / [1.0.0] — 注入打通

- **1.0.2**：加对照组（注入「设置」App）+ 多路径日志
- **1.0.1**：过滤器加厚（`Bundles` + `Executables`）
- **1.0.0**：手搓 clang + 自建 DEB 首版

**关键结论**：SpringBoard 注入在本机（Dopamine-roothide 真越狱 / iOS 16.2）**成功**，
且 **SpringBoard 天然拥有蓝牙 TCC 权限**（实测 `蓝牙状态 = 5 (已开启)`，并能扫到周边设备）。
