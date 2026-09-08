# 架构

## 三个目标

| Xcode target | 职责 | Bundle ID |
| --- | --- | --- |
| EnglishHintKeyboard | 主 App、配置与试用 | com.tutuhu.EnglishHintKeyboard |
| EnglishHintKeyboardExtension | 固定26键中文键盘 | com.tutuhu.EnglishHintKeyboard.Keyboard |
| EnglishHintNineKeyExtension | 固定九宫格中文键盘 | com.tutuhu.EnglishHintKeyboard.NineKey |

两个扩展复用同一份键盘代码，通过各自 Info 的 `EHKKeyboardLayout` 固定布局。输入法注册由 iOS 设置管理。钥匙串访问组的前缀来自签名团队，后缀保持 `com.tutuhu.EnglishHintKeyboard`。

## 主应用

`App/EnglishHintKeyboardApp.swift` 只承担入口。`Home`、`Translation`、`Keyboard`、`About` 按功能分文件；`DesignSystem` 提供页面、分组、按钮与图标；`Support` 负责展示名称及调试状态记录。

页面继续拥有各自的SwiftUI状态；服务配置的校验和持久化统一交给 `TranslationSettingsStore`。共享界面组件不能直接读取Keychain或发网络请求。

## 输入与翻译

`KeyboardViewController` 协调系统文本代理、拼音组合、生命周期、翻译与替换。`KeyboardSurface` 只绘制键盘并转发动作；`SentenceAnalysisPanel` 只呈现学习内容。

`LiveHintModel` 提取输入并去抖，通过 `SelectedHintTranslator` 选择苹果/千问/自定义。请求以revision隔离，输入改变、重置或离开后不能发布旧结果；同步订阅者重入也不能让旧输入发起请求。

`AppleInstalledTranslator` 使用 Apple Translation 和已准备语言包。云端传输有明确超时、响应上限、取消、无缓存和拒绝重定向限制；只有临时云端故障才尝试设备端备用。

## 学习与替换

`SentenceAnalysisSession` 按当前英文和完整服务设置做仅内存的预分析/复用。`SentenceAnalyzer` 验证返回的结构化数据；结构校验不能保证模型语法解释的正确性。

`HintReplacement` 是与UIKit无关的规划和执行规则：要求准确的当前快照、无选区/已知右侧正文、完整短句后缀。宿主编辑不是原子操作，取消中断时仅在可核实的部分编辑上回滚。一次撤销随着真实编辑或上下文变化失效。

## 拼音引擎

Objective-C++ `PinyinDecoder` 串行使用AOSP引擎，并隔离各控制器的候选快照和已选前缀。`NineKeyPinyinDecoder` 通过真实拼音表做有界搜索；生成的临时搜索缓存只在内存中。用户选词学习字典在扩展沙盒，测试必须使用独立临时字典。
