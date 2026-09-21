# BWMonitor

[中文](#中文) | [English](#english)

## 中文

BWMonitor 是一款原生 macOS VPS 监控与管理应用。首个版本聚焦
BandwagonHost/KiwiVM 流量数据，以及经系统 OpenSSH 客户端采集的实时
Linux 指标。

项目主页：https://github.com/Mujh05/BWMonitor

### 功能

- 多服务器配置，非敏感数据存本地
- KiwiVM `getServiceInfo` 接入，三分钟刷新策略
- SSH 主机密钥校验，独立 `known_hosts`
- CPU、内存、交换空间、磁盘、负载、运行时间与网络速率采集
- 原生 SwiftUI 仪表盘、历史图表、服务/进程视图与终端
- 菜单栏状态、WidgetKit 小组件、通知与登录启动
- API 密钥、密码、私钥密码只存 macOS 钥匙串
- 中英文界面，跟随 macOS 应用语言设置
- GitHub Releases 更新通道

应用内不嵌入任何 API 密钥或密码。后台监控使用私钥或 SSH agent；
密码登录只在交互式终端里处理。

### 安装

从 [Releases](https://github.com/Mujh05/BWMonitor/releases/latest)
下载 `BWMonitor-1.0.dmg`，打开后把 BWMonitor 拖进 Applications 即可。
签名版可直接运行；小组件需在桌面右键 → 编辑小组件 → 添加。

### 更新

应用启动时每周自动检查一次 GitHub Releases（静默，无更新不打扰），
也可手动前往**设置 → 关于 → 软件更新**检查。

### 构建

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BWMonitor.xcodeproj -scheme BWMonitor \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

核心测试可单独运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

用 `--demo` 启动参数可离线预览界面。App Group 与登录启动行为需要
正常签名的本地构建。

### 语言

BWMonitor 跟随 macOS 的语言设置。如只想给 BWMonitor 单独指定语言，
打开**系统设置 → 通用 → 语言与地区 → 应用程序**，添加 BWMonitor 后
选择中文或英文。

---

## English

BWMonitor is a native macOS VPS monitor and manager. The first release focuses on
BandwagonHost/KiwiVM traffic data plus live Linux metrics collected over the
system OpenSSH client.

Project home: https://github.com/Mujh05/BWMonitor

### Features

- Multiple-server configuration with non-sensitive data stored locally
- KiwiVM `getServiceInfo` integration with a three-minute refresh policy
- Verified SSH host keys and strict per-app `known_hosts`
- CPU, memory, swap, disk, load, uptime, and network-rate collection
- Native SwiftUI dashboard, history charts, services/process views, and terminal
- Menu bar status, WidgetKit extension, notifications, and launch at login
- Keychain storage for API keys, passwords, and private-key passphrases
- English and Simplified Chinese UI that follows the macOS app language
- GitHub Releases update channel

The app never embeds API keys or passwords. Background monitoring uses a private
key or the user's SSH agent; password authentication is handled only inside the
interactive terminal.

### Install

Download `BWMonitor-1.0.dmg` from
[Releases](https://github.com/Mujh05/BWMonitor/releases/latest), open it, and
drag BWMonitor into Applications. The signed build runs directly; to use the
widget, right-click the desktop → Edit Widgets → add BWMonitor.

### Updates

BWMonitor checks GitHub Releases automatically at launch (at most once a week,
silently unless an update is found), or manually from
**Settings > About > Software Update**.

### Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BWMonitor.xcodeproj -scheme BWMonitor \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Core tests can also run independently:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Use the `--demo` launch argument to preview the interface without contacting a
server. App Group and launch-at-login behavior require normal local signing.

### Language

BWMonitor follows the language selected by macOS. To choose a language only for
BWMonitor, open **System Settings > General > Language & Region > Applications**,
add BWMonitor, then select English or Simplified Chinese.
