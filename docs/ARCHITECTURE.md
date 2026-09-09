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

`HintContextExtractor` 返回系统给定的before+after草稿，有非空selectedText时则仅使用选区。仅去除最外层空白，内部空行与标点原样保留；400字符上限按完整候选范围判断，超出返回inputLimited，不取局部片段。模型清除旧译文和动作并显示长度提示，不发翻译/分析或重试请求，缩短后正常恢复。控制器不移动光标遍历全文；iOS代理自身可能只提供部分内容。翻译完成后的完整英文直接作为学习范围。

千问多段翻译仍是一次Qwen-MT请求：原文位于唯一user消息，官方translation_options.domains描述多段聊天草稿及尽量保留段落的格式。自定义接口使用同样的完整翻译提示。返回值仅trim最外层空白，不因模型调整了段落数而拒绝或自动重试。

`AppleInstalledTranslator` 使用 Apple Translation 和已准备语言包。云端传输有明确超时、响应上限、取消、无缓存和拒绝重定向限制；只有临时云端故障才尝试设备端备用。

## 学习与替换

`SentenceAnalysisSession` 按当前英文和完整服务设置做仅内存的预分析/复用。`SentenceAnalyzer` 验证返回的结构化数据；结构校验不能保证模型语法解释的正确性。

分析包含可选 `wordMeanings` 与 `structure`。词义按编号词元关联，结构使用半开词元区间；展示统一转为原英文UTF16范围，缩写和连字符词保持完整。缺失新字段兼容旧响应，无效可选条目局部丢弃；分析主体与表达仍严格校验原文来源。词义随分析提前生成，点击不新增查词请求。输入上限1600字符，请求预算随词数增长至最多16384输出token，25秒时限、128 KiB响应上限。

`SentenceAnalysisPanel` 保留唯一原文视图；颜色与主干聚焦只更新文字属性，不改变字形位置。精确点击范围关联本句词义，经 `onLookupChanged` 更新Surface固定44 pt顶栏；无语音服务时仍可查已有词义。分析迟到时就地补充当前选词，普通点读和播放更新不滚动。仅显式「看原文」保存讲解位置并定位；独立「返回讲解」条恢复原位置。收起或换句清除临时选择。

`HintReplacement` 是与UIKit无关的规划和执行规则：要求准确的当前快照、无选区、无已知右侧正文、准确原文后缀，编辑前后均低于400字符。多段草稿作为一次编辑/撤销；选区只允许翻译与学习，不据此猜测后缀删除范围。末尾空白使译文源与后缀不再精确匹配时仍拒绝替换。宿主编辑不是原子操作，取消中断时仅在可核实的部分编辑上回滚。一次撤销随着真实编辑或上下文变化失效。

## 拼音引擎

Objective-C++ `PinyinDecoder` 串行使用AOSP引擎，并隔离各控制器的候选快照和已选前缀。`NineKeyPinyinDecoder` 通过真实拼音表做有界搜索；生成的临时搜索缓存只在内存中。用户选词学习字典在扩展沙盒，测试必须使用独立临时字典。

## 英文听读

控制器只在当前服务为千问、完全访问可用、英文与宿主快照一致时暴露朗读入口。点击时重新校验设置；英文生成和分析预取不会自动产生语音调用。苹果和自定义模式不使用留存的千问密钥。

`QwenSpeechSynthesizer` 使用北京地域的 `qwen3-tts-flash`、Cherry音色、English语言。键盘通过同一个POST的SSE逐段接收24 kHz/16 bit/单声道PCM，收到片段就交给播放器，不等待完整WAV或再下载OSS文件。API Key仅发往固定千问端点，所有重定向均拒绝；解析和Base64解码在独立actor，有8 MiB网络体积、1 MiB事件和最终4 MiB音频上限，单次PCM交付不超过8192字节；20秒网络空闲与120秒资源总时限为播放背压保留长句时间。流式完成必须收到stop且PCM完整，才包装WAV供重听；部分失败不缓存或自动重试。参考[官方接口](https://help.aliyun.com/zh/model-studio/qwen-tts-api)与[流式PCM播放说明](https://help.aliyun.com/zh/model-studio/non-realtime-tts-user-guide)。原有完整生成方法保留给不支持流播放的消费者，不作为失败后的自动付费回退。

`SpeechPlaybackSession` 管理点击、取消、错误、当前句内存缓存与旧结果隔离；`KeyboardAudioPlayer` 首播使用AVAudioEngine/AVAudioPlayerNode顺序播放PCM，播放队列有界，队列满时暂停读取后续片段。接收完成与播放完成分开，最后一段实际播放完才恢复idle。缓存重听继续使用AVAudioPlayer，所有路径均为正常速率播放一遍。界面只接收状态并转发动作，音频不写磁盘。编辑、替换、设置切换、宿主失活或内存告警会清理缓存；展开/收起学习与纯键面切换不打断同一句。音频中断、耳机断开和媒体服务重置停止且不自动恢复，无录音与后台音频模式。

学习原文通过只读UITextView提供字词命中和原生选区；正文仍为18 pt/28 pt行高，仅外层学习区滚动。表达按钮读经过验证的source。Controller在每次点击时重新校验服务、完整译文、宿主快照和片段来源，收起后的过期回调不触发请求。状态经Surface传回Panel，轻高亮与按钮更新不重建内容。

整句与片段共用单个播放会话；scopeID为当前完整译文，配置或宿主上下文变化时清理。LRU缓存最多12条且合计不超过4 MiB；切片段取消旧请求、停止旧声音，有缓存即复用。无语音预取或整句音频裁切，每个未缓存片段只在明确点读时独立生成。
