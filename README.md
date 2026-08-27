# SN3延伸板（Snapper3 extension board）

一个依附在 **Snapper3** 上的扩展插件，和 **Snapper3 Expand** 用同一种方式挂载：
通过 Snapper3 自带插件管理器 `Snapper3PluginManager registerPlugin:` 把自己注册进
Snapper3 的截图动作菜单。专注解决“内置/云端 OCR 不识别中文”，且**不依赖**任何付费云端
OCR Token —— 中文 OCR 用苹果本地 Vision，完全离线免费。

本工程**必须在 Mac（或 Linux）上用 Theos 编译**，Windows 上无法产出 arm64 二进制。

---

## 功能

| 动作 | 说明 | 是否需要配置 |
|---|---|---|
| **OCR** | 本地 Apple Vision 文字识别，默认简体/繁体中文 + 英文，离线免费；识别结果在原图上高亮文字块，点框即复制该处内容 | 无 |
| **翻译** | 先本地 OCR，再把结果送百度翻译，译文+原文一起展示；支持自定义目标语言（zh/en/jp/kor/fra/spa/ru/de/it/pt/th/vie/ara） | 需要百度翻译 AppID / 密钥 |
| **长截图** | 滚动当前页面主滚动区域并拼接长图，先预览后点按钮保存；帧间重叠/最大高度/帧间等待均可调，消除拼接缝隙 | 无需密钥，参数可调 |
| **问 AI** | 先本地 OCR，再把图中文字发给 OpenAI 兼容接口（DeepSeek/OpenAI/自建），底部输入框可连续追问，保留上下文 | 需要 API Key / 接口地址 / 模型名 |

设置面板会出现在 设置 → SN3延伸板。

---

## 目录结构

```
Snapper3ZhExt/
├── Makefile                         # Theos 构建（rootless / arm64）
├── control                          # Debian 包元信息
├── Snapper3ZhExt.plist              # Substrate 注入白名单（仅 SpringBoard）
├── Tweak.xm                         # Logos：hook Snapper3PluginManager 注册 4 个插件
├── src/
│   ├── PluginBase.h/.m              # Snapper3Plugin 协议实现（全部关键 selector 均接管）
│   ├── ZhOCRPlugin.h/.m             # OCR 插件
│   ├── VisionOCR.h/.m               # 本地 Vision 中文 OCR（含文字块坐标）
│   ├── OCRBoxWindow.h/.m            # OCR 框选定位：高亮文字块 + 点框复制
│   ├── TranslatePlugin.h/.m         # 翻译插件
│   ├── TranslateEngine.h/.m         # 百度翻译 API
│   ├── LongScreenshotPlugin.h/.m    # 长截图插件
│   ├── LongShotController.h/.m      # 滚动拼接实现（可调重叠/高度/等待）
│   ├── AskAIPlugin.h/.m             # 问 AI 插件
│   ├── AskAIEngine.h/.m             # OpenAI 兼容对话补全（多轮 messages）
│   ├── AIChatWindow.h/.m            # 多轮对话面板（底部输入框连续追问）
│   ├── ResultWindow.h/.m            # 可复用的半屏结果浮层（可选字+复制）
│   └── Common.h/.m                  # 偏好读写 / 图标 / 工具
└── layout/
    └── var/jb/Library/{PreferenceBundles,PreferenceLoader}/…  # 设置面板（纯 plist，零编译）
```

## 在 Mac 上构建

1. 安装 Theos：`git clone --recursive https://github.com/theos/theos ~/theos`
   （还要装 Homebrew 的 `xz`、`ldid` 等，Theos 文档可查）。
2. 打开 `Snapper3ZhExt` 目录，设好环境变量并编译打包：

   ```bash
   export THEOS=/Users/<你>/theos
   export THEOS_PACKAGE_SCHEME=rootless      # 无根，与你的“无根”deb 一致
   export THEOS_DEVICE_IP=你的手机局域网IP     # 可选，配合 make do
   make clean && make package
   ```

3. 产物在 `packages/` 下，得到 `com.axs.snapper3zhext_1.1.0-1_iphoneos-arm64.deb`。

## 安装（无根 / 别名根）

- 方式一：把 `.deb` 传到手机，用 **Sileo / Zebra** 打开安装。
- 方式二：`make do` 或 `make install`（需配好 `THEOS_DEVICE_IP` 与 OpenSSH）。
- 前置依赖（`control` 已声明会自动装）：`mobilesubstrate`、`preferenceloader`、iOS ≥ 14。
- 必须先装 **Snapper3**（主体），本扩展是在它的插件系统里注册。

安装完成后到 设置 → SN3延伸板 里填好所需密钥；然后**注销（Respring）**，
启动 Snapper3 截图后，动作菜单里会出现新的 OCR / 翻译 / 长截图 / 问AI 图标。

---

## 使用流（以 OCR 为例）

1. 正常触发 Snapper3 截图（音量+电源或 Activator 手势）。
2. 框选要识别的区域。
3. 在动作菜单点新加的 **OCR** 图标。
4. 半屏浮层在原图上高亮每个文字块，点一下某个框立即复制该处文字；下方按钮可“复制选中 / 复制全部”。

翻译 / 问AI 同理，会先本地 OCR。翻译可选择目标语言；问AI 会先回答一次，
底部输入框可继续输入追问，保持上下文（多轮对话）。长截图先出预览，点“保存到相册”才落盘。

---

## 已知说明与需要在真机调试的点

- **注册稳健性**：`Tweak.xm` 通过 hook `Snapper3PluginManager` 的
  `+sharedInstance` / `+defaultManager` / `-init` 做一次惰性注册，避免 dylib 加载顺序问题。
  这是参考 **Snapper3 Expand** 的做法。若 Snapper3 后续版本连插件协议都变了，需按新协议调整。
- **长截图**：用的是“滚动 + 分层渲染拼接”常见方案，不同的 App / 列表实现效果可能不同，
  属于最需要真机调试的一项。若某页面拼接错位，优先调 `LongShotController.m` 里的步进来完成。
- **翻译 / 问 AI 需要各自平台的自备密钥**，否则对应动作会提示未配置。
- 偏好默认存 `/var/mobile/Library/Preferences/com.axs.snapper3zhext.plist`。

---

## 原理小结（逆向结论，供你了解为什么可行）

- Snapper3 本体内置 OCR 是苹果 **Vision** `VNRecognizeTextRequest`，语言列表随
  “算法版本 + 精度”动态生成，默认只偏向英文，因此中文常识别不出。
- Snapper3 自带**第一方插件系统**：`Snapper3PluginManager`（单例）→ `registerPlugin:`，
  插件实现 `Snapper3Plugin` 协议（`pluginIdentifier` / `wantsToSnapRect:inImage:thenDoPlugin:`）后
  就会出现在截图动作菜单。
- **Snapper3 Expand**（你给的 `Snapper3Expand.dylib`）正是靠 `registerPlugin:` 把
  `AxsOCRPlugin` 等注册进去的；而它的 OCR 走 **PaddleOCR 云端 API**，必须自备付费 Token。
  本扩展换成本地 Vision，解决了中文识别且不再依赖付费云端 OCR。