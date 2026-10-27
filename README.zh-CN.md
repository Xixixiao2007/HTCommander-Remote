# HTCommander-Remote

[English](README.md) | **简体中文**

这是 [Handi-Talky Commander](https://github.com/Ylianst/HTCommander) 的一个分支，
在原有功能之上增加了**原生远程控制**：同一个应用，既可以接着电台对外提供服务，
也可以作为次级客户端连到这样一台主机上操作。

> **本仓库是修改后的衍生作品，依 Apache License 2.0 发布。**
> 它不是官方发行版，上游作者不对这里的改动负责。
> 变更声明见 [NOTICE](NOTICE)（Apache-2.0 §4(b) 要求），原始项目见
> [Ylianst/HTCommander](https://github.com/Ylianst/HTCommander)。

---

## 本分支增加了什么

| | 上游 | 本分支 |
| --- | --- | --- |
| 本地使用（蓝牙接电台） | 有 | 有，**未作改动** |
| **主机角色**：对外提供远程连接 | 无 | **有** —— 令牌鉴权、单人操作员锁、审计留痕 |
| **客户端角色**：远程操作一台主机 | 无 | **有** —— 镜像主机状态，双向音频 |
| 音频档位 | — | **32 / 16 / 8 kHz** 可选 |
| 从远端发射 | — | **有**，按住说，受操作员权限门控 |

这个功能是**可选的**。保持默认（`设置 → 远程控制 → 关闭`）时，应用行为与上游完全一致。

设计、安全模型、主机与客户端如何配置、以及哪些还没接上，都在
**[REMOTE-CONTROL.md](REMOTE-CONTROL.md)** 里（英文）。

动手之前有两条默认值会让人意外：

1. **主机只监听 `127.0.0.1`。** 另一台机器上的客户端连不上，除非你勾选
   *接受来自网络内其它设备的连接*。
2. **主机强制要求令牌，而且初始一个都没有。** 在同一设置区块的
   *访问令牌* 里生成一个，并**立刻复制密钥**——它只显示一次。

---

## ⚠️ 网络转发的法律与合规风险

**这一节请在做任何端口转发之前读完。**

### 发射的责任不随连接转移

用本软件发射，前提是你在**你所在的辖区**具备合法的操作资格与台站许可。
具体要求各地不同，也不在本文范围内——请自行确认。

远程控制**不改变**责任归属：发射的责任始终落在持证的操作者身上，
物理上谁坐在机器前并不重要。因此：

- 把令牌交给没有操作资格的人，等于让**你的**许可去发射。
- 你在别人的主机上发射，仍受你自己所在辖区规则的约束。
- 远程操作常见于"人不在台站旁"的场景，而这类情形在很多地方另有条件要求。

**是否允许远程发射、允许到什么程度，由你所在辖区的规定决定，
不属于本项目的判断范围。** 本文与项目文档均**不构成法律意见**。

### 暴露端口 = 把发射能力放到网上

默认状态下主机只监听本机回环地址。一旦你勾选局域网访问，或用反向代理把端口
转发到公网，性质就变了：**任何拿到有效令牌的人，都能用你的电台发射。**

具体建议：

- **不要把端口直接裸露在公网上。** 用带 TLS 的反向代理（Caddy、nginx、
  Cloudflare Tunnel 等）在前，应用本身只监听内网。
- **令牌按设备分发，不用了就吊销。** 一个令牌对应一台设备，泄露时只断开那一台。
- **定期看审计表。** 软件会记录每次连接、被拒的连接、被拒的写入，以及每次发射
  （含令牌名与来源地址）。这是事后自查与追责的依据。

### 软件提供了什么、不提供什么

| 提供了 | 不提供 |
| --- | --- |
| 强制令牌鉴权（主机启动即生效） | **任何合规保证** |
| 单人操作员锁：只有持权者能发射 | 替你判断你是否被允许远程发射 |
| 完整审计（连接、拒绝、写入、发射） | 对受管制频段/功率的自动限制 |
| 局域网访问默认关闭 | 对上游链路的加密（TLS 由反代负责） |

合规是你和你的监管机构之间的事，软件只能把"谁做了什么"记清楚。

---

## 怎么拿到可运行的程序

**本分支没有预构建的安装包。** 上游的安装包**不包含**远程控制功能，
下载它们拿不到这个仓库加的东西。

### 从源码构建

需要先装 [Flutter](https://docs.flutter.dev/get-started/install)。
本分支的开发环境是 **Flutter 3.47.8 / Dart 3.13.7**。

```bash
cd src
flutter pub get
flutter build windows --release      # 或 build linux / build macos / build apk / build ios
```

在 Windows 上，实测还需要两个环境变量才能构建干净：

```powershell
$env:CL = '/utf-8'                              # 源码是 UTF-8，默认代码页会报 C4819/C2220
$env:CMAKE_POLICY_VERSION_MINIMUM = '3.5'       # CMake 4 不接受插件里钉住的旧策略版本
```

另外，带插件的构建需要**符号链接支持**：打开 Windows「开发者模式」，
或用管理员权限运行终端。

### 或者：直接用上游的包，并放弃本分支的功能

如果你只想要基础版本，[上游发行版](https://github.com/Ylianst/HTCommander/releases)
才是对的二进制——那是原项目，由原作者维护。它们**不含**远程控制。

---

## 上游功能（本分支未改动）

面向 EchoLink 以及 UV-Pro、UV-50Pro、GA-5WB、VR-N75、VR-N76、VR-N7500、
VR-N7600 等电台的业余无线电（HAM）跨平台工具，只要蓝牙可用，就支持
Windows、macOS、Linux、iOS、Android 和 Web。

使用本软件发射需要业余无线电操作证。办证信息可看
[ARRL 的说明](https://www.arrl.org/getting-licensed)（英文）。

### 电台支持

EchoLink 以及下列电台应当可用：

- BTech UV-Pro、UV-50Pro
- Radioddity GA-5WB、DB50-B Mini
- Vero VR-N75、VR-N76、VR-N7500、VR-N7600
- Radtel RT-660

### 全平台功能

- [信道编程](https://ylianst.github.io/HTCommanderSite/features/channels.html)：配置、导入、导出，拖放即可编排信道。
- [APRS 支持](https://ylianst.github.io/HTCommanderSite/features/aprs.html)：收发 APRS 消息、设路由、给手机发短信、查天气、发认证消息。
- [BSS 支持](https://ylianst.github.io/HTCommanderSite/features/bss.html)：宝锋 / BTech 的私有短消息二进制协议。
- [APRS 地图](https://ylianst.github.io/HTCommanderSite/features/map.html)：基于 OpenStreetMap，一眼看清所有 APRS 台站。
- [Winlink 邮件](https://ylianst.github.io/HTCommanderSite/features/winlink.html)：在 Winlink 网络上收发邮件，支持附件。
- [通讯录](https://ylianst.github.io/HTCommanderSite/features/address-book.html)：APRS、Winlink、终端联系人。
- [终端](https://ylianst.github.io/HTCommanderSite/features/terminal.html)：与其它台站、用户或 BBS 进行 packet 通信。
- [BBS](https://ylianst.github.io/HTCommanderSite/features/bbs.html)：内置一个基础 BBS，同时可作 Winlink 网关。
- [抓包](https://ylianst.github.io/HTCommanderSite/features/capture.html)：内置抓包解码。
- [GPS](https://ylianst.github.io/HTCommanderSite/features/gps.html)：电台固件支持时可用。
- [种子文件交换](https://ylianst.github.io/HTCommanderSite/features/torrent.html)：在 1200 波特的 FM-AFSK 上做多对多传输。

### Windows / Linux / macOS / Android 另有

- [蓝牙音频](https://ylianst.github.io/HTCommanderSite/features/bluetooth-audio.html)：用电脑音箱、麦克风或耳机收听与发射。
- [SSTV](https://ylianst.github.io/HTCommanderSite/features/sstv.html)：收发图像，接收自动识别。
- [语音转文字](https://ylianst.github.io/HTCommanderSite/features/voice.html)与文字转语音。

### 仅桌面端（Windows / Linux / macOS）

- [AGWPE 协议](https://ylianst.github.io/HTCommanderSite/features/agwpe.html)：让其它应用通过电台收发。

---

## 许可与归属

- **许可**：[Apache License 2.0](LICENSE)，与上游一致。本分支**没有**重新授权任何内容。
- **变更**：[NOTICE](NOTICE) 记录了加了什么、涉及哪些文件。
- **原始项目**：[Ylianst/HTCommander](https://github.com/Ylianst/HTCommander)
  —— 官方发行版所在地，也是在不启用本分支远程控制功能时仍能复现的问题的反馈处。
- **上游网站**：<https://ylianst.github.io/HTCommanderSite/>

### 致谢

本工具的协议解码基于 Kyle Husmann（KC3SLD）的工作与
[BenLink](https://github.com/khusmann/benlink) 项目，后者解出了这些电台的蓝牙指令。
另外用到 Lee（K0QED）的 [APRS-Parser](https://github.com/k0qed/aprs-parser)。

地图数据来自 [openstreetmap.org](https://openstreetmap.org)。

APRS 消息补齐使用 [aprs.fi](https://aprs.fi) 的 API，由 Heikki Hannikainen（OH7LZB）提供。

中继台目录检索由 [RepeaterBook](https://www.repeaterbook.com) 提供。RepeaterBook
要求每个用户各自申请 API 令牌。
