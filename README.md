# SundiroSPUnlock

把「新大洲本田」蓝牙**无感解锁**独立成 **SpringBoard 插件**，不再依赖官方 App。
车况遥测 / 小组件 / 深链控制仍由官方 App 侧组件负责，两者互不干扰。

**当前版本：1.2.0** ｜ 支持 `iphoneos-arm64e`（RootHide）与 `iphoneos-arm64`（rootless）

---

## 为什么能独立

解锁协议**完全自包含**，取自官方 App 的实测数据：

| 依赖项 | 来源 |
|:--|:--|
| 4 帧协议报文 | 离线造帧（XOR 校验 + `AA AA` 尾） |
| 49 组 `(R, R3)` 配对 | 硬编码常量表（官方 App 实测采集） |
| 32 字节常量 | 硬编码 |
| 服务/特征 UUID | `FFF0 / FFF1 / FFF6`（硬编码） |
| 网络 / token / 官方 App | **完全不需要** |

**核心机制**：iOS 会无限期保持一个「挂起的蓝牙连接」（pending connect）。
插件在 SpringBoard 里挂上它，车一进入范围 iOS 就自动完成连接，插件立刻发四帧解锁。

> 官方 App 也能做这件事，但**会被 iOS 挂起**。**SpringBoard 永远不会被挂起** —— 这就是独立成插件的意义。
> 实测：pending connect 存活 **6 小时 26 分**，期间零人工干预，车一出现即连上并解锁。

---

## 实测数据

| 指标 | 实测值 |
|:--|:--|
| pending connect 存活 | **6 小时 26 分**（另一次 2 小时 50 分） |
| 解锁握手耗时 | **1256 ~ 2297 ms**（官方 App 版 2116 ms） |
| 待机耗电 | 9 小时 **0 次扫描 / 0 次连接**（仅挂 pending connect） |
| 定时器 | 15 秒一跳；iOS 会主动合并（实测 568 跳仅触发 71 次心跳） |

### v1.2.0 真机验收（2026-10-10 · 2 小时 15 分 · 24 次解锁）

| 指标 | v1.2.0 实测 | 同日志 v1.1.6 对照 |
|:--|:--|:--|
| 解锁发起 / 完成 | 24 / **19（79%）** | 28 / 26（93%） |
| 四帧耗时 中位 / 最小 / 最大 | **3107 / 1755 / 5325 ms** | 3593 / 1970 / 5820 ms |
| 链路断开（`⚠️ 断开`） | 36 次（0.27 次/分） | 34 次（0.30 次/分） |
| 异常 / 崩溃 | **0** | 0 |
| 扫描次数 | **0**（retrieve 一次命中） | 0 |
| 心跳 | #8→#528，**步长恒 8（零漏拍）** | — |

**结论：10 项加固全部真机生效，协议路径零回归，秒解锁速度未退化。**
同一份日志、同一环境下，1.2.0 四帧耗时中位（3107 ms）**低于** 1.1.6（3593 ms）；
所有新增逻辑只挂在异常路径，正常解锁一次都不触发。
（注：早前另一环境测得 1.1.6 中位 2693 ms，跨环境不可直接比较。）

**5 次未完成（#4/#5/#8/#9/#23）全部为环境性链路断开，非代码缺陷**，签名统一：
`写特征 FFF6 就绪 → 立刻直发` → 帧 1（有时帧 2）→ `⚠️ 断开：timed out`。
本日志跨 v1.0.4→v1.2.0 共 **92 次发起 / 82 完成 / 10 未完成 —— 10/10 未完成全部由「链路断开」造成**，
无一次是看门狗超时、写失败或状态卡死；各版本断开率同量级（0.27~0.30 次/分）⇒ **环境性，与版本无关**。

> `Failed to encrypt the connection` 是 iOS 链路层配对失败，成因为车端被其他主设备
> （通常是官方 App）占用链路，**非插件可控**（后续「互斥/让位」议题）。

---

## 修复记录

| # | 问题 | 根因 | 状态 |
|:--|:--|:--|:--|
| **A1** | 车已解锁仍每 30 秒重发四帧（实测 8 分钟 17 次） | `_doneLink` 是死守卫——只读、从未赋值，判重恒为假 | ✅ 真机验证：修复后严格 1:1 |
| **A2** | `订阅 FFF1` / `写特征就绪` 1 秒内刷 4 次 | `didDiscoverCharacteristicsForService` 被多次回调 | ✅ 真机验证：降为 1 次 |
| **A3** | 重连退避只增不减，封顶后**永久锁死 30 秒** | `backoff` 是 `static` 局部变量，全工程无重置点 | ✅ 真机验证：断开后回到 `1 秒` |
| **P1** | 扫描占空比 83%（偏耗电） | 1.0.7 为加速实测把冷却从 60s 改成 20s，未改回 | ✅ 已恢复 60s（占空比 → 42%） |

### v1.2.0 加固（10 项，协议路径零改动）

| # | 缺陷 | 根因 | 真机状态（2026-10-10） |
|:--|:--|:--|:--|
| **A1** | 仅第 1 帧设看门狗，2/3/4 帧无超时 | 原阈值 3.0s = 实测最慢 f1→f2 零余量；三条恢复路径全堵死 | ✅ 改为每步 8s 看门狗 + 代际校验 + 有界自愈 |
| **A2** | `didWriteValueForCharacteristic` 缺失 | 四帧 WithResponse 却无写回执 | ✅ 已实现；本轮 0 次写失败 |
| **B1** | 注释称“串行”实为并发队列 | `dispatch_get_global_queue`，共享状态无锁 | ✅ 专用串行队列 |
| **B2** | `tryConnect` 守卫非原子 | 1.1.6 铁证同秒双发 connect | ✅ **v1.2.0 段 0 次同秒双发** |
| **C1** | kill-switch/logpath 未适配 RootHide jbroot | `return` 在日志初始化前，无法留痕 | ✅ 日志先行；“装载”行即证明安全阀被检查 |
| **C2** | `SPKnownVehicleUUID()` 无缓存 | `_car`=nil 时每 15s 全目录扫描 | ✅ **v1.2.0 段 0 次扫描** |
| **C3** | 计时用墙钟 | 回拨会让冷却/扫描锁死 | ✅ `CLOCK_MONOTONIC` |
| **D1** | 日志每行写 6 个文件 | 轮转只覆盖 1 个，I/O 压在解锁关键路径 | ✅ 只写单一可写路径 |
| **D2** | 非 SB 宿主仍启动 15s 定时器 | SPTick 未随引擎启停 | ✅ 已移入 `start` |
| **D3** | 死代码 `kSvcFFF0`/`kAppPrefs`/`lastCarFrame` | 定义即唯一出现 | ✅ 已删（源码 0 处） |

---

## 构建

由 GitHub Actions 构建（`macos-14` + `roothide/theos` + `ldid`）：

```
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

CI 同时产出：

| scheme | 架构 | 适用 |
|:--|:--|:--|
| `roothide` | `iphoneos-arm64e` | **RootHide / Dopamine-roothide** |
| `rootless` | `iphoneos-arm64` | Dopamine（传统 rootless） |

> ⚠️ 两个架构**不可同时安装**。

---

## 安装

用 **Sileo / Zebra** 安装（不要用 `dpkg -i` —— 那样会跳过 RootHide 的安装钩子），
装完执行 `killall -9 SpringBoard`。

---

## 验证

装好后到车附近，重启桌面并看日志：

```sh
killall -9 SpringBoard
cat /var/mobile/Library/Logs/sundirosp.log
```

**期望看到**（真实日志节选）：

```
════ SundiroSPUnlock v1.1.4 装载 pid=9343 uid=501 bundle=com.apple.springboard ════
蓝牙状态 = 5 (已开启)
车辆 UUID = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
retrieve 已知 UUID 命中 1 个外设
认车 SDH-xxxxxx (…) — retrieve
连接请求 -> SDH-xxxxxx
✅ 已连接 SDH-xxxxxx (累计 1 次)
服务 FFF0
订阅 FFF1（车的回帧从这条来）
写特征 FFF6 就绪 → 立刻直发
-> 解锁帧 1/4（配对 #0） … 4/4
★ 四帧发完 —— 耗时 1347 ms（累计成功 1 次）
```

**日志标签速查**

| 标签 | 含义 |
|:--|:--|
| `[boot]` | 启动 / 装载 / 蓝牙状态 |
| `[probe]` | 车辆 UUID / 车名读取过程 |
| `[link]` | 扫描 / 认车 / 连接 / 断开 / 重试 |
| `[gatt]` | 服务与特征发现 / FFF1 订阅状态 |
| `[direct]` | 四帧握手推进 |
| `[car]` | 车的回帧 |
| `[life]` | 每 2 分钟心跳（含外设状态） |

> **找不到日志？** 插件同时写 `NSLog`（可在 Console 查看），并内置另外 **5 个候选路径**
> （`/var/mobile/Library/Preferences/com.jibamao.spsundiro.log`、`/var/mobile/Documents/`、
> `/var/jb/var/mobile/Library/Logs/`、`/tmp/`、`/var/tmp/`），不怕单一沙盒拦截。

**心跳怎么读**

| 心跳字段 | 含义 |
|:--|:--|
| `外设状态=1` | Connecting（正在等车） |
| `外设状态=2` | Connected（已连上） |
| `已连=N` / `已解锁=M` | 累计连接次数 / 累计成功解锁次数；**两者应 1:1**（A1 门禁） |

---

## 控制

| 动作 | 命令 |
|:--|:--|
| 立即停用 | `touch /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` 后 `killall -9 SpringBoard` |
| 恢复 | `rm /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` |
| 只关解锁（保持连接） | 偏好域 `com.jibamao.spsundiro` 写 `unlock = NO` |
| 卸载 | Sileo 卸载，或删 `DynamicLibraries/SundiroSPUnlock.{dylib,plist}` |

---

## 安全设计

SpringBoard 崩 = 注销，开机崩 = 白苹果循环，因此：

1. **kill-switch 是第一件事** —— 文件存在就直接 return，绝不碰蓝牙
2. 全部逻辑在后台队列，**不阻塞 SpringBoard 启动路径**
3. 逐层 `@try/@catch`，异常绝不外泄
4. **不做任何 swizzle**（纯新增行为）
5. 非 busy-loop —— 15 秒 tick + 退避 1→30 秒（**连上即复位**）+ 解锁冷却 20 秒 + 同链路只发一轮

---

## 过滤器

```xml
Filter = { Bundles = [com.apple.springboard], Executables = [SpringBoard] }
```

---

## 已知限制

- **与官方 App 会抢链路** —— 建议用前把官方 App 从后台划掉。
  1.2.0 起同秒双发连接请求已消除，但**两个 central 争同一辆车**这一点本质未变。
- 日志中偶见 `Failed to encrypt the connection` —— 在官方 App 版日志里也出现过，归因**蓝牙弱信号**；
  另一常见诱因是**同时有另一个 central 连着车**。二者无法从日志区分。
- 「车 UUID 未知」时（App 从未连过车）会进入扫描模式，认车最多多等 60 秒。
- **车回帧仅按长度匹配**（26 / 42）—— 这是继承自已量产官方 App 的宽松匹配，
  收紧只会降低解锁成功率，故保持原样。详见 CHANGELOG「明确不改」。

## 安全阀（kill-switch）

创建以下文件后注销桌面（respring）即停用，删除后重新注销即恢复：

```
/var/mobile/Library/Preferences/com.jibamao.spsundiro.off
```

1.2.0 起会同时探测**真实根 / `/var/jb`（rootless）/ 全部 `.jbroot-*`（RootHide）**，
所以无论你用哪种工具创建，都能被认到；命中时日志会留一行
`★ kill-switch 命中（<路径>）—— 不启动蓝牙`，可直接验证。

---

## 许可证

[MIT](LICENSE)
