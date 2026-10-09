# 开发指南

在仓库根运行命令。需要macOS 26、完整Xcode 26.4+和Python 3，无第三方包管理器依赖。

## 构建

```sh
python3 scripts/generate-project.py
scripts/xcode-project.sh version
EHK_CONFIGURATION=Release scripts/xcode-project.sh build-device CODE_SIGNING_ALLOWED=NO build
```

脚本优先采用 `EHK_XCODE_APP`，然后是已有 `DEVELOPER_DIR` / 系统选择的Xcode，最后检测常见安装位置；不会修改全局 `xcode-select`。自定义路径：

```sh
EHK_XCODE_APP=/path/to/Xcode.app EHK_BUILD_DIR=/path/to/build scripts/test.sh
```

打开 `EnglishHintKeyboard.xcodeproj` 也可构建。工程由生成器管理，新增/移动Swift文件或资源后重新生成。当前版本常量在 `scripts/generate-project.py`；三个目标版本必须一致。

## 真机签名

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# 编辑 Local.xcconfig 中 DEVELOPMENT_TEAM
EHK_CONFIGURATION=Release scripts/xcode-project.sh build-device build
```

本机已有签名团队会在目录整理时迁移到Local文件。克隆到另一台Mac需自行登录Apple开发账户、选择团队；改团队会改变钥匙串前缀，不能承诺读取旧安装的配置。不要为了排查键盘注册先删除App。

产物默认在 `build/Products/Release-iphoneos/EnglishHintKeyboard.app`。使用Xcode Devices and Simulators安装，或用devicectl选择明确的设备UUID安装；不要将设备UUID或签名材料写进仓库。

## 在另一台Mac给iPad安装

1. 克隆公开仓库 `https://github.com/HututuWorks/Banyu.git` 并切到要验证的提交；使用自己的Apple账号登录Xcode Settings → Accounts。需要完整Xcode 26.4+及匹配的iOS开发组件。
2. 用数据线连接iPad，在设备上信任电脑；设备最低iPadOS 26.0。按Xcode要求在设备「设置 → 隐私与安全性」启用开发者模式并完成重启确认。
3. 打开根目录 `EnglishHintKeyboard.xcodeproj`，为App、26键扩展和九宫格扩展三个Target选择同一个Team，启用Automatically manage signing。或者配置被忽略的 `Config/Local.xcconfig` 中的DEVELOPMENT_TEAM。
4. 选择 `EnglishHintKeyboard` Scheme 和连接的iPad，点击Run。由Xcode为这台设备创建签名并安装，不要把其他人的开发IPA当成通用安装包。若提示Bundle ID不可用，需要派生一套独立的App/两个扩展ID并同步钥匙串组；只改单个Target会导致配置共享或安装失败，先保留报错交给维护者处理。
5. 安装后，在「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」分别添加伴语26键和九宫格；使用云端服务时允许完全访问，并在主App填写自己的配置。

免费Personal Team有设备/App ID与短期签名限制，通常需要每7天重新签名安装。持续向朋友分发建议使用付费Apple Developer Program的TestFlight或登记设备分发。仓库访问权限与设备安装权限是两回事。

参考：[Apple个人团队限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[登记设备分发](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)。

## 日常修改

- 先确定职责目录，保持视图与翻译/设置规则分离。
- 修复问题应添加能在旧行为上失败的用例。
- 运行适用测试，再运行Release构建和 `python3 scripts/check-repository.py`。
- 提交前检查 `git diff --check` 与 `git status`，不能包含 `build/`、Local签名配置、API Key或用户数据。

GitHub Actions使用macOS 26 runner，跑无网络本地测试和无签名iPhone/iPad通用构建。需要桌面会话的Catalyst UI检查在开发Mac运行。

## 构建组件与CI产物

Xcode 的 asset catalog 编译需要匹配的 iOS 模拟器运行时。即使仅构建真机包，缺失时也可能报 `No available simulator runtimes`。在 Xcode → Settings → Components 安装，或使用苹果官方命令：

```sh
xcodebuild -downloadPlatform iOS -architectureVariant arm64
```

先确保系统盘有足够空间。组件安装方式见[Apple文档](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)。

每个成功的 CI 会保存无签名 `Banyu-unsigned-<commit>` artifact 7天。它不能直接安装到手机，也不含证书和描述文件。开发者可下载核对 SHA256 后用自己的开发签名安装；正常开发仍推荐直接在完整 Xcode 环境构建。
