# 1.3.0 改动与构建

## 改动（协议路径零改动）
1. 撤销 1.2.15 的 RSSI >= -80 连接门禁（`tryConnect` / `didDiscoverPeripheral`）：恢复 pending connect 常挂，链路提前备好，按键才有承载通道。
2. 解锁触发改为两条（`didConnectPeripheral` / `didDiscoverCharacteristicsForService`）：
   - 车主动发按键帧 → 立即四帧（`_forceSend`，不受门禁影响）；
   - 睡醒首连（挂起 >= 20 秒且非闪断）→ 自动解一轮；闪断重连不再自动解。
3. `forceReconnect` 加 3 秒节流（`_connReqAt`），修掉 AllowDuplicates 下每个广播包都重发连接请求。
4. 蓝牙关闭/重开时清 `_lastRSSI/_lastSeenAt/_connAt/_linkReady/_unlockOnReady`。

## 入口
`%ctor` 是 Theos 专用，已换成 `__attribute__((constructor)) static void SPInit(void)`，并加 os_log 信标 `ApelinLoaded <buildID>`（`-DAPELIN_BUILD_ID=…`），不影响功能。

## 构建
Theos：`make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide`
源文件是 `Tweak.x`，Makefile 里 `SundiroSPUnlock_FILES = Tweak.x`；`-fobjc-arc` 必需。
`build.sh` 是在设备上用 clang 直接编译的替代脚本（仅供参考）。
