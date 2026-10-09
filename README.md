# SundiroSPUnlock

把「新大洲本田」蓝牙无感解锁**独立成 SpringBoard 插件**，不再依赖官方 App。
车况遥测 / 小组件 / 深链控制仍由官方 App 侧组件负责，两者互不干扰。

## 为什么能独立

解锁协议**完全自包含**，取自官方 App 的实测数据：

| 依赖项 | 来源 |
|:--|:--|
| 4 帧协议报文 | 离线造帧（XOR 校验 + `AA AA` 尾） |
| 49 组 `(R, R3)` 配对 | 硬编码常量表（官方 App 实测采集） |
| 32 字节常量 | 硬编码 |
| 服务/特征 UUID | `FFF0 / FFF1 / FFF6`（硬编码） |
| 网络 / token / 官方 App | **完全不需要** |

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

## 安装

用 **Sileo / Zebra** 安装（不要用 `dpkg -i`——那样会跳过 RootHide 的安装钩子），
装完 `killall -9 SpringBoard`。

## 验证

**注意 roothide 的路径语义**：bootstrap 命令行工具只认 jbroot 路径，
真实 iOS 文件系统在 `/rootfs/`。本插件是**普通 clang/ObjC**（未用 vroot），
它写的是**真实路径**，所以从终端要看：

```sh
cat /rootfs/var/mobile/Library/Logs/sundirosp.log
```

期望看到：

```
════ SundiroSPUnlock v1.0.3 装载 pid=xxx uid=501 bundle=com.apple.springboard ════
蓝牙状态 = 5 (已开启)
认车 SDH-xxxxxx — 名字命中
✅ 已连接 …
-> 解锁帧 1/4 … 4/4
★ 四帧发完
```

同时插件也会写 NSLog（统一日志）与另外 5 个候选路径，不怕单一沙盒拦截。

## 控制

| 动作 | 命令 |
|:--|:--|
| 立即停用 | `touch /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` 后 `killall -9 SpringBoard` |
| 恢复 | `rm /var/mobile/Library/Preferences/com.jibamao.spsundiro.off` |
| 卸载 | Sileo 卸载，或删 `DynamicLibraries/SundiroSPUnlock.{dylib,plist}` |

## 安全设计

SpringBoard 崩 = 注销，开机崩 = 白苹果循环，因此：

1. **kill-switch 是第一件事** —— 文件存在就直接 return，绝不碰蓝牙
2. 全部逻辑在后台队列，**不阻塞 SpringBoard 启动路径**
3. 逐层 `@try/@catch`，异常绝不外泄
4. **不做任何 swizzle**（纯新增行为）
5. 非 busy-loop：退避 1→30 秒 + 解锁冷却 20 秒 + 同链路只发一轮

## 过滤器

```xml
Filter = { Bundles = [com.apple.springboard, com.apple.Preferences], Executables = [SpringBoard] }
```

`com.apple.Preferences` 是**对照组**：打开「设置」若能出日志，说明注入链路通，
只有 SpringBoard 不出则问题在 SpringBoard 专属策略。上线后可删掉这一项。
