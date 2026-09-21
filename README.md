# BWMonitor

[中文](#中文) | [English](#english)

## 中文

BWMonitor 是一款原生 macOS VPS 监控与管理应用。首个版本聚焦
BandwagonHost/KiwiVM 流量数据，以及经系统 OpenSSH 客户端采集的实时
Linux 指标。

项目主页：https://github.com/Mujh05/BWMonitor

### 功能

- 多服务器配置，非敏感数据存本地
- 在应用内完成 SSH 连接设置：核对并信任主机密钥、选择或创建密钥、
  把公钥安装到服务器、测试连接
- KiwiVM `getServiceInfo` 接入，三分钟刷新策略
- SSH 主机密钥校验，独立 `known_hosts`
- CPU、内存、交换空间、磁盘、负载、运行时间与网络速率采集
- 原生 SwiftUI 仪表盘、历史图表、服务/进程视图与终端
- 菜单栏状态、WidgetKit 小组件、通知与登录启动
- API 密钥、密码、私钥密码只存 macOS 钥匙串
- 中英文界面，跟随 macOS 应用语言设置
- 从 GitHub Releases 自动更新，一键完成

### 连接服务器

在**服务器 → 添加服务器**中填写主机、端口和用户名，然后：

1. **主机密钥**：点“检查主机密钥”，核对指纹后点“信任”。如需确认，可在
   服务商的网页控制台运行 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
   对比。之后主机密钥一旦变化，BWMonitor 会拒绝连接。
2. **登录方式**：
   - **SSH 密钥**（推荐）：可以直接用 `~/.ssh` 里已有的密钥、选择其他密钥
     文件、粘贴私钥，或者让 BWMonitor 创建自己的密钥。如果服务器上还没有
     这个公钥，点“安装到服务器…”，输入一次服务器密码即可自动添加到
     `~/.ssh/authorized_keys`，已有的密钥不受影响。带私钥密码的密钥也能
     用于后台监控。
   - **密码**：也能用于监控。点“设置密钥登录…”可一键创建密钥、装到服务器
     并改用密钥登录。
3. 点“测试连接”确认能登录，然后保存。监控会自动开始。

BWMonitor 自己创建的密钥保存在
`~/Library/Application Support/BWMonitor/Keys/`，和 `~/.ssh` 里的密钥一样
只有你的用户账户能读取；在**设置 → 安全**里可以拷贝它的公钥。

### 安全

- 密码和私钥密码只保存在钥匙串中，并且只保留当前登录方式需要的那一项。
- ssh 需要密码时，通过 BWMonitor 自带的 askpass 程序向正在运行的 BWMonitor
  索取；密码不会出现在命令行、环境变量、文件或终端输出里。只有 BWMonitor
  自己启动的 ssh 才能拿到。
- 监控期间每台服务器保持一个 SSH 连接，不会每隔几秒重新登录。登录失败时
  BWMonitor 会停止重试，避免服务器因多次失败而屏蔽你的 IP。

### 安装

从 [Releases](https://github.com/Mujh05/BWMonitor/releases/latest)
下载 `BWMonitor-<版本>.dmg`，打开后把 BWMonitor 拖进 Applications 即可。
签名版可直接运行；小组件需在桌面右键 → 编辑小组件 → 添加。

### 更新

BWMonitor 每天在后台检查一次 GitHub Releases，没有新版本时不打扰。有新版本时，
侧边栏和菜单栏窗口会出现提示，点“立即更新”即可：BWMonitor 会下载安装包，
核对更新说明里的 SHA-256 和签名，原地替换自己，然后重新打开，服务器和设置
都保持不变。也可以在菜单 **BWMonitor → 检查更新…** 或
**设置 → 关于 → 软件更新**里手动检查。

1.2 起才能自动更新；1.1 及更早的版本需要手动安装一次 1.2。
如果 BWMonitor 所在位置无法替换（比如直接从安装包里运行），会改为打开新版本的
安装包，把它拖进“应用程序”即可。

### 构建

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BWMonitor.xcodeproj -scheme BWMonitor \
  -configuration Debug -derivedDataPath .build/DerivedData.noindex \
  CODE_SIGNING_ALLOWED=NO build
```

构建目录名以 `.noindex` 结尾，开发版不会被 Spotlight 收录进启动台。

核心测试可单独运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

另有一组连接真实 SSH 服务器的测试，设置以下环境变量后才会运行（对 Linux
服务器还会实际采集一次指标）：

```sh
BWMONITOR_TEST_SSH_HOST=127.0.0.1 BWMONITOR_TEST_SSH_PORT=2222 \
BWMONITOR_TEST_SSH_USER=$USER BWMONITOR_TEST_SSH_KEY=/path/to/key swift test
```

用 `--demo` 启动参数可离线预览界面。App Group 与登录启动行为需要
正常签名的本地构建。未签名的构建每次重新编译后，读取钥匙串时 macOS
会重新询问一次。

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
- SSH setup inside the app: verify and trust the host key, choose or create a
  key, install it on the server, and test the connection
- KiwiVM `getServiceInfo` integration with a three-minute refresh policy
- Verified SSH host keys and strict per-app `known_hosts`
- CPU, memory, swap, disk, load, uptime, and network-rate collection
- Native SwiftUI dashboard, history charts, services/process views, and terminal
- Menu bar status, WidgetKit extension, notifications, and launch at login
- Keychain storage for API keys, passwords, and private-key passphrases
- English and Simplified Chinese UI that follows the macOS app language
- One-click self-update from GitHub Releases

### Connecting a server

Choose **Servers > Add Server**, enter the host, port, and user name, then:

1. **Host Key**: click Check Host Key, compare the fingerprint, and click
   Trust. To be sure, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
   in your provider's web console. BWMonitor refuses to connect if the key
   ever changes.
2. **Sign-In**:
   - **SSH Key** (recommended): use a key from `~/.ssh`, choose another key
     file, paste a private key, or let BWMonitor create its own key. If the
     server does not have the public key yet, click Install on Server… and
     enter the server password once; the key is added to
     `~/.ssh/authorized_keys` and existing keys are kept. Keys protected by a
     passphrase work for background monitoring too.
   - **Password**: works for monitoring as well. Set Up Key Login… creates a
     key, installs it, and switches the server to key login in one step.
3. Click Test Connection, then Save. Monitoring starts automatically.

Keys that BWMonitor creates live in
`~/Library/Application Support/BWMonitor/Keys/`; like the keys in `~/.ssh`,
only your user account can read them. Copy the public key from
**Settings > Security**.

### Security

- Passwords and passphrases are kept only in the Keychain, and only the ones
  the chosen sign-in method needs.
- When ssh needs a secret, BWMonitor's askpass helper asks the running app for
  it. Secrets never appear in command lines, environment variables, files, or
  terminal output, and only ssh processes started by BWMonitor can get them.
- Monitoring keeps one SSH connection per server instead of logging in every
  few seconds. After a rejected login BWMonitor stops retrying, so the server
  does not block your IP address for repeated failures.

### Install

Download `BWMonitor-<version>.dmg` from
[Releases](https://github.com/Mujh05/BWMonitor/releases/latest), open it, and
drag BWMonitor into Applications. The signed build runs directly; to use the
widget, right-click the desktop → Edit Widgets → add BWMonitor.

### Updates

BWMonitor checks GitHub Releases once a day in the background and stays quiet
unless there is a new version. Then a reminder appears in the sidebar and the
menu bar window; click Update Now and BWMonitor downloads the installer, checks
its SHA-256 from the release notes and its signature, replaces itself in place,
and reopens, keeping your servers and settings. You can also check from
**BWMonitor > Check for Updates…** or **Settings > About > Software Update**.

Automatic updates start with 1.2; install 1.2 by hand once if you have 1.1 or
earlier. If BWMonitor cannot be replaced where it is (for example when it runs
from the installer), the new installer opens instead; drag BWMonitor into
Applications.

### Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BWMonitor.xcodeproj -scheme BWMonitor \
  -configuration Debug -derivedDataPath .build/DerivedData.noindex \
  CODE_SIGNING_ALLOWED=NO build
```

The build folder ends in `.noindex`, so Spotlight does not add development
builds to Launchpad.

Core tests can also run independently:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Tests against a real SSH server run only when these variables are set (against
a Linux server they also collect real metrics):

```sh
BWMONITOR_TEST_SSH_HOST=127.0.0.1 BWMONITOR_TEST_SSH_PORT=2222 \
BWMONITOR_TEST_SSH_USER=$USER BWMONITOR_TEST_SSH_KEY=/path/to/key swift test
```

Use the `--demo` launch argument to preview the interface without contacting a
server. App Group and launch-at-login behavior require normal local signing.
With unsigned builds, macOS asks again for Keychain access after every rebuild.

### Language

BWMonitor follows the language selected by macOS. To choose a language only for
BWMonitor, open **System Settings > General > Language & Region > Applications**,
add BWMonitor, then select English or Simplified Chinese.
