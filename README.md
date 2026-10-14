# ServerDock

[中文](#中文) | [English](#english)

## 中文

ServerDock 是原生 macOS / iOS 服务器监控与 SSH 应用。Mac 使用系统 OpenSSH，
iPhone / iPad 通过原生 SSH 客户端直接连接 Linux 服务器，并支持安全文件传输。

项目主页：https://github.com/Mujh05/BWMonitor

### 功能

- 多服务器配置，非敏感数据存本地
- 在应用内完成 SSH 连接设置：核对并信任主机密钥、选择或创建密钥、
  把公钥安装到服务器、测试连接
- KiwiVM `getServiceInfo` 与 AWS Lightsail `NetworkIn`/`NetworkOut` 月流量
- SSH 主机密钥校验，独立 `known_hosts`
- CPU、内存、交换空间、磁盘、负载、运行时间与网络速率采集
- 原生 SwiftUI 仪表盘、历史图表、服务/进程视图与终端
- 菜单栏状态、WidgetKit 小组件、通知与登录启动
- API 密钥、密码、私钥密码只存 macOS 钥匙串
- 中英文界面，跟随 macOS 应用语言设置
- 从 GitHub Releases 自动更新，一键完成
- 面向 AI 和脚本的 `serverdock` 命令行接口，输出稳定 JSON；旧的 `bwmonitor` 命令继续兼容
- 远程文件夹浏览、隐藏文件切换、文件上传和下载；Mac 可从访达拖拽文件上传
- iPhone / iPad 原生服务器管理、系统监控、月流量、文件与远程命令

### 支持的平台

所有平台都通过 SSH 支持 CPU、内存、磁盘、网络速率、终端和文件操作。
平台名称不会限制连接：其他 Linux VPS 选择“通用 Linux”即可。

| 平台 | 服务商月度流量 API |
| --- | --- |
| BandwagonHost / KiwiVM | 支持 |
| AWS Lightsail | 支持，UTC 自然月入站 + 出站 |
| Vultr | 支持，UTC 每日记录聚合，出站计费 |
| Hetzner Cloud | 支持，当月出站计费字节数 |
| DigitalOcean、阿里云、腾讯云、Oracle Cloud | 暂未接入计费 API；SSH 监控和文件功能可用 |

Vultr 与 Hetzner 的实例 ID 和只读 Token 可在服务器编辑界面填写，Token 仅存
钥匙串。不填 API 凭据仍可使用 SSH 功能。Vultr 显示的单实例套餐配额是参考值，
不等同账户共享流量池；Hetzner API 不返回精确重置时刻，界面标注日历月计费。
新平台 API 已用固定响应验证；配置实际 Token 后才能验证对应账户的实时数据。

官方接口与计费说明：[Vultr API](https://www.vultr.com/api/)、
[Vultr 流量池](https://docs.vultr.com/support/platform/billing/how-are-bandwidth-caps-calculated)、
[Hetzner API](https://docs.hetzner.cloud/reference/cloud)、
[Hetzner 计费](https://docs.hetzner.com/cloud/billing/faq/)。

### 文件管理

选择服务器后打开“文件”，默认进入 SSH 用户的主目录。支持上级目录、直接输入
路径、隐藏文件、多文件上传和下载。Mac 可点击“上传”或将访达文件拖到列表。
上传使用同一套主机指纹与认证配置，传输走加密 SFTP，同名远端文件不会被覆盖。
当前支持文件上传，整个文件夹上传尚未实现。传输时可取消。
Mac 的目录列表需要服务器有 GNU `find`；iOS 通过 SFTP 列目录。

### AWS Lightsail 流量

把服务器的服务商设为 **AWS Lightsail**，填写实例名称和区域，再保存只读 AWS
凭据。凭据只进入 macOS 钥匙串。所需最小读取权限为 `GetInstance`、
`GetBundles`、`GetInstanceMetricData`。应用按 UTC 自然月显示入站、出站、合计、
套餐配额、更新时间和历史趋势；后台刷新失败时保留上一次成功数据并标记错误。

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
下载 `ServerDock-<版本>-arm64.dmg`，打开后把 ServerDock 拖进 Applications 即可。
签名版可直接运行；小组件需在桌面右键 → 编辑小组件 → 添加。

### 命令行与 AI 接口

安装终端命令（只需执行一次）：

```sh
/Applications/ServerDock.app/Contents/MacOS/BWMonitor --cli install-cli
```

之后可直接使用：

```sh
serverdock servers
serverdock status                 # 查询全部服务器实时指标
serverdock status "Server name"   # 按名称、主机或 UUID 查询
serverdock traffic                # 查询全部 KiwiVM / AWS 流量
serverdock files "Server name" --path /var/www
serverdock upload "Server name" ./index.html --to /var/www
serverdock download "Server name" /var/www/index.html --to ./downloaded.html
serverdock exec "Server name" -- uname -a
serverdock shell "Server name"    # 打开交互式 SSH
```

数据命令默认输出带 `schemaVersion` 的 JSON，适合 AI 和脚本解析。接口复用
应用已有的服务器配置、主机密钥与钥匙串；密码、API Key 和私钥密码不会写入
命令参数或输出。

`files` 返回文件元数据而不读取文件内容；上传拒绝同名覆盖，CLI 下载也拒绝覆盖
本地已有文件。所有命令继续使用 `schemaVersion: 1`。

### iOS / iPadOS

使用 Xcode 打开 `ServerDockIOS.xcodeproj`，选择 `ServerDockIOS` scheme。
最低支持 iOS 18，iPhone 与 iPad 使用原生导航和系统字体，支持深色模式和动态字体。
手机直接连接服务器，不依赖 Mac 中转。

可在手机添加服务器，或从设置导入服务器 JSON；配置文件不包含密码、私钥或
API Token，凭据需在手机单独填写。首次 SSH 连接会显示 SHA256 主机指纹，需要
核对后确认；已信任主机更换密钥会阻止连接。私钥保存在设备钥匙串中。
支持 Ed25519 / RSA OpenSSH 私钥，以及未加密 RSA PEM 导入。当前 iOS SSH
依赖的 RSA 认证使用旧 `ssh-rsa` 签名；仅允许 RSA SHA2 的现代服务器请使用
Ed25519 或密码认证。不要为兼容应用降低服务器的 SSH 算法设置。
iOS 的“终端”执行一次性远程命令，不支持交互式 `vim` / `top`；Mac 仍保留交互终端。
进入后台后监控会受 iOS 生命周期限制，返回前台可继续刷新。

模拟器构建：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ServerDockIOS.xcodeproj -scheme ServerDockIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath work/ServerDockIOSBuild CODE_SIGNING_ALLOWED=NO build
```

真机安装需要在 Xcode 为 iOS target 选择自己的开发者团队并连接 iPhone。
模拟器验收不代表已经安装到真机，也不代表已经发布到 App Store。

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

ServerDock is a native macOS and iOS server monitoring and SSH app. It collects
Linux metrics, browses remote folders, and transfers files over SSH/SFTP. macOS
uses system OpenSSH; iOS connects directly through Citadel, without a Mac relay.

Project home: https://github.com/Mujh05/BWMonitor

### Features

- Multiple-server configuration with non-sensitive data stored locally
- SSH setup inside the app: verify and trust the host key, choose or create a
  key, install it on the server, and test the connection
- KiwiVM `getServiceInfo` and AWS Lightsail `NetworkIn`/`NetworkOut` monthly traffic
- Verified SSH host keys and strict per-app `known_hosts`
- CPU, memory, swap, disk, load, uptime, and network-rate collection
- Native SwiftUI dashboard, history charts, services/process views, and terminal
- Menu bar status, WidgetKit extension, notifications, and launch at login
- Keychain storage for API keys, passwords, and private-key passphrases
- English and Simplified Chinese UI that follows the macOS app language
- One-click self-update from GitHub Releases
- A `serverdock` command-line interface for AI and scripts with stable JSON output; `bwmonitor` remains a compatible alias
- Remote folder browsing, file uploads/downloads and Finder drag-and-drop uploads on Mac
- Provider traffic APIs for Vultr and Hetzner; DigitalOcean, Alibaba Cloud, Tencent Cloud and Oracle Cloud support SSH monitoring, commands and files
- Native iPhone/iPad target in `ServerDockIOS.xcodeproj`, with separate device Keychain credentials and explicit host-fingerprint trust

Vultr/Hetzner usage counts outbound bytes. Vultr's displayed instance allowance
is not its account-wide shared billing pool. Hetzner's reset date is a computed
calendar-month estimate, not a timestamp returned by its API. Adapters have
fixture coverage; live provider validation requires your own read-only tokens.
Folder uploads and interactive iOS terminal sessions are not implemented.

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

Download `ServerDock-<version>-arm64.dmg` from
[Releases](https://github.com/Mujh05/BWMonitor/releases/latest), open it, and
drag ServerDock into Applications. The signed build runs directly; to use the
widget, right-click the desktop → Edit Widgets → add BWMonitor.

### Command-line and AI interface

Install the terminal command once:

```sh
/Applications/ServerDock.app/Contents/MacOS/BWMonitor --cli install-cli
```

Then use it directly:

```sh
serverdock servers
serverdock status
serverdock status "Server name"
serverdock traffic
serverdock files "Server name" --path /var/www
serverdock upload "Server name" ./index.html --to /var/www
serverdock download "Server name" /var/www/index.html --to ./downloaded.html
serverdock exec "Server name" -- uname -a
serverdock shell "Server name"
```

Data commands emit versioned JSON for AI and scripts. The CLI reuses the app's
server settings, pinned host keys, and Keychain items; passwords, API keys, and
private-key passphrases are never included in arguments or output.

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
