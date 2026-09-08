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

## 英文听读

控制器只在当前服务为千问、完全访问可用、英文与宿主快照一致时暴露朗读入口。点击时重新校验设置；英文生成和分析预取不会自动产生语音调用。苹果和自定义模式不使用留存的千问密钥。

`QwenSpeechSynthesizer` 使用北京地域的 `qwen3-tts-flash`、Cherry音色、English语言。先请求合成，再下载同次生成的WAV；API Key仅发往固定千问端点，下载使用不带Key的新请求。参考[千问听读示例](https://platform.qianwenai.com/docs/developer-guides/speech/tts)与[官方接口](https://help.aliyun.com/zh/model-studio/qwen-tts-api)。仅允许文档列出的OSS域名，HTTP示例地址在发请求前升级HTTPS，所有重定向均拒绝。生成20秒、下载15秒上限，JSON32 KB、音频4 MB上限，下载字节处理不占主actor。

`SpeechPlaybackSession` 管理点击、取消、错误、单句内存缓存与旧结果隔离；`KeyboardAudioPlayer` 使用系统AVAudioPlayer以正常速率播放一遍，自然结束或主动停止时释放播放实例并恢复idle。自然结束保留当前句音频，再次点读无需重新生成。界面只接收状态并转发动作，音频不写磁盘。编辑、替换、设置切换、宿主失活或内存告警会清理缓存；展开/收起学习与纯键面切换不打断同一句。音频中断、耳机断开和媒体服务重置停止且不自动恢复，无录音与后台音频模式。
