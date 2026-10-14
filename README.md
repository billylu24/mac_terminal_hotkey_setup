# macOS Terminal 全局热键

在 macOS 的任意应用中使用：

| 快捷键 | 功能 |
| --- | --- |
| Control + Option + T（`⌃⌥T`） | 在用户主目录打开新的 Terminal 窗口 |
| Control + Option + W（`⌃⌥W`） | 关闭最近打开的 Terminal 窗口 |

关闭窗口前会检查是否有正在运行的命令；如果有，会先询问。首次使用关闭快捷键时，macOS 会询问是否允许 **Terminal Hotkeys** 控制 **Terminal**，请选择“允许”。之后可在“系统设置 → 隐私与安全性 → 自动化”中修改。

## 安装

需要 macOS 和 Xcode Command Line Tools。如果尚未安装开发工具，先运行 `xcode-select --install`。无需第三方应用或管理员密码。

```sh
git clone https://github.com/billylu24/mac_terminal_hotkey_setup.git
cd mac_terminal_hotkey_setup
./install.sh
```

脚本会在本机编译 [源码](src/TerminalHotkey.swift)，安装到 `~/Library/Application Support/TerminalHotkey/`，并通过 LaunchAgent 在登录后自动启动。更新时执行 `git pull && ./install.sh`。重新编译后，macOS 可能再次请求“自动化”权限。

## 卸载

```sh
./uninstall.sh
```

脚本会停止后台程序，删除安装的应用和 LaunchAgent。日志及旧备份会保留在 `~/Library/Application Support/TerminalHotkey/`。

## 工作方式与诊断

程序使用 Terminal 自带的“自动化”接口读取窗口。按每个窗口中最早启动的终端会话判断窗口创建顺序；已退出的会话以 Terminal 窗口 ID 为备用顺序。无法读取标签页的非普通终端窗口会跳过。没有终端窗口时，关闭热键不会执行操作。

安装后可运行以下诊断命令：

```sh
"$HOME/Library/Application Support/TerminalHotkey/Terminal Hotkeys.app/Contents/MacOS/terminal-hotkey" --diagnose
```

`--validate` 仅检查内置脚本语法。`--self-check` 会新建一个临时空窗口，确认它被选为最近窗口，然后关闭该临时窗口。
