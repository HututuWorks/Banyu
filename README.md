<p align="center"><img src="App/Assets.xcassets/BrandLogo.imageset/BrandLogo.png" width="96" alt="伴语 Logo" /></p>
<h1 align="center">伴语 · Banyu</h1>
<p align="center">照常输入，英文随行。</p>

[![Build and test](https://github.com/SciToolsmith/Banyu/actions/workflows/ci.yml/badge.svg)](https://github.com/SciToolsmith/Banyu/actions/workflows/ci.yml)

伴语是一个 iPhone 中文键盘：正常打字时查看英文提示，主动点「用英文」替换当前句，也可以展开学习英文用法。主 App 用于试用、管理键盘和配置翻译服务。

## 功能

- 「伴语·26键」与「伴语·九宫格」两个独立系统键盘入口，使用真实 AOSP 拼音词典。
- Apple 设备端翻译、千问翻译，以及用户配置的 OpenAI 兼容接口。
- 轻量英文提示栏；长句保持字号，上下滑动阅读。
- 显式替换与一次撤销；不会自动发送消息。
- 约半屏的整句精读：原文、关键用法和实用表达。支持的云端服务提前分析，展开即可复用结果。
- 系统字体、浅深色外观，用户提供的伴语 Logo。

## 开发环境

- macOS 26、完整 Xcode 26.4 或更新版本、Swift 6、Python 3。
- 目标为 iPhone，最低 iOS 26.0。最新本地验证使用 Xcode 26.6。
- 当前版本：0.1.0 / Build28。App 与两个键盘扩展必须一起构建。

```sh
python3 scripts/generate-project.py
scripts/test.sh
EHK_CONFIGURATION=Release scripts/xcode-project.sh build-device CODE_SIGNING_ALLOWED=NO build
```

真机签名时，将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig` 并设置自己的开发团队。该文件不会进入 Git；现有安装使用原 bundle ID 与钥匙串组，避免丢失已有配置。详见 [开发指南](docs/DEVELOPMENT.md)。

## 目录

| 目录 | 职责 |
| --- | --- |
| `App/` | 按功能组织的 SwiftUI 页面、共享界面组件和品牌资源 |
| `Keyboard/` | UIKit 键盘、拼音桥接、九宫格适配与学习面板 |
| `Shared/` | 翻译、设置、句子分析、请求状态和替换规则 |
| `Config/` | 生成的 Info.plist、共享签名配置和 entitlements |
| `Tests/` | 可重复的本地回归与隔离 UI 验证 |
| `Resources/` | 实际使用的拼音词典 |
| `Vendor/`、`Licenses/` | 固定版本的第三方代码、来源与许可 |
| `scripts/` | 工程生成、构建、测试与仓库检查入口 |
| `docs/` | 架构、开发、测试、隐私与已知限制 |

历史原型、旧安装包、截图、参考仓库及缓存已从工作目录移出；它们不属于构建或 Git 仓库。新的生成产物统一进入忽略的 `build/`。

## 安装与使用

1. 系统设置 → 通用 → 键盘 → 键盘 → 添加新键盘，在伴语下分别添加所需布局。
2. 点开每个已添加的伴语键盘，分别开启「允许完全访问」。
3. 在输入框长按地球键，切换到伴语。主 App 的「试用键盘」可用于检查。
4. 使用苹果翻译时先准备所需语言包；使用云端服务时先测试配置，再主动启用。

## 更多说明

[架构](docs/ARCHITECTURE.md) · [测试](docs/TESTING.md) · [数据处理](docs/PRIVACY.md) · [已知限制](docs/KNOWN_ISSUES.md) · [本轮审查](docs/AUDIT.md) · [变更记录](CHANGELOG.md)

API Key 只保存在设备共享钥匙串。源码、测试、构建产物和 GitHub 仓库不包含用户密钥、聊天记录或真机诊断数据。

本项目尚未指定整体开源许可；第三方部分分别遵守其原许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。
