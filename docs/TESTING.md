# 测试

## 无网络回归

```sh
scripts/test.sh
```

包含：输入去抖/重试/取消/状态重入、设置与端点校验、千问/自定义请求、语音请求/取消/缓存/中断、准确替换与撤销、分析数据/会话、学习区高度、真实拼音词典与九宫格。拼音桥使用AddressSanitizer与UndefinedBehaviorSanitizer，测试字典在临时目录自动清理。

每套测试可单独运行：`scripts/test-core.sh`、`scripts/test-settings.sh`、`scripts/test-qwen.sh`、`scripts/test-replacement.sh`、`scripts/test-analysis.sh`、`scripts/test-analysis-session.sh`、`scripts/test-study-layout.sh`、`scripts/test-pinyin.sh`。

语音服务与会话分别运行 `scripts/test-speech-service.sh`、`scripts/test-speech-playback.sh`。覆盖请求格式、下载不带Key、域名/大小边界、无自动重试、超长拒绝、取消与迟到结果隔离、单句复用与配置变更。

## 原生UI回归

在有桌面登录会话的macOS中运行：

```sh
scripts/test-keyboard-lifecycle.sh
scripts/test-speech-surface.sh
scripts/test-app-ui.sh
# 或一起执行
scripts/test.sh --ui
```

生命周期测试运行真实UIKit控制器和内存文本代理。App截图运行复制的SwiftUI源码及品牌资源，用内存配置替换Keychain、阻断云端传输，并stub语言包准备。所有输出在被忽略的 `build/`。

Mac Catalyst截图不是iPhone截图；大字场景验证条件布局，不能替代iPhone实际字体缩放、系统键盘安装、触摸和宿主组合布局验证。

## 真机检查清单

1. 两个键盘分别添加、分别允许完全访问，并在系统键盘列表可选。
2. 中文组合、候选选择、删除、数字/符号切换、26键/九宫格输入。
3. 英文提示长句滚动、主动替换、一次撤销、纯键面切换保留动作。
4. 学习面板展开、滚动、收起再开；新输入不显示旧分析。
5. 临时切到后台时停止长按删除和请求；回到原输入框能继续输入。
6. 主App浅深色、辅助功能大字、试用输入、服务配置和Logo。
7. 在千问模式点小喇叭首次出声，正常语速读一遍后自动停止并恢复图标；朗读中再点停止，等待时再点取消；读完再次点同一句无需重新生成。输入、替换、切后台/其他输入框后不会播放旧句。
8. 语音失败提示、语音权限不足/无网络、耳机拔出、来电、微信语音与静音开关；苹果/自定义模式不会发起千问语音请求。

本地测试使用固定句/假服务，无真实Keychain读取、付费API调用或聊天发送。翻译模型的真实质量和网络体验需要单独验收。
