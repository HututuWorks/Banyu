# 第三方来源与许可

## AOSP PinyinIME

实际拼音解码与词典来自Android官方仓库，固定提交 `49aebad1c1cfbbcaa9288ffed5161e79e57c3679`，Apache 2.0。来源、校验值和本地适配说明见 [Vendor说明](Vendor/AOSPPinyin/README.integration.md) 与 `Vendor/AOSPPinyin/UPSTREAM.json`。许可在 `Licenses/AOSP-Pinyin-NOTICE.txt`，随App及扩展分发。

## translatekb

键盘布局实现参考 [aminbenarieb/translatekb](https://github.com/aminbenarieb/translatekb)，固定版本 `44f01020763b6564fc4901f5b347de3796cc61f5`，MIT。许可保存在 `Licenses/translatekb-LICENSE.txt`，随主App分发，衍生文件保留来源说明。

## 其他研究参考

输入事件及任务失效的早期研究参考 [jtvargas/SnipKey](https://github.com/jtvargas/SnipKey)；未携带其云同步、付费或片段数据库模块。研究用完整仓库已移出工作目录，不是构建依赖。

Apple Translation、SwiftUI、UIKit等系统框架不随源码分发翻译模型。模型由Apple系统在准备语言包时提供。项目Logo为用户提供的原始品牌素材，未从第三方仓库提取。
