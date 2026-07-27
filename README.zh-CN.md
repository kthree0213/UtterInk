# UtterInk

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/wordmark-lockup-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="Brand/wordmark-lockup.svg">
    <img alt="UtterInk" src="Brand/wordmark-lockup.svg" width="420">
  </picture>
</p>

<p align="center">
  <strong>隐私优先、本地优先的 macOS 听写工具。</strong><br>
  开口说话，在本机完成转写，并把文字安全送到你正在输入的位置。
</p>

<p align="center">
  <a href="https://github.com/kthree0213/UtterInk/releases/tag/v0.1.0">下载 v0.1.0</a>
  · <a href="README.md">English</a>
  · <a href="PRIVACY.md">隐私说明</a>
</p>

UtterInk 是一款开源的 macOS 菜单栏本地 Whisper 听写应用。Raw 听写内容留在这台 Mac；只有当你主动启用 AI 润色时，UtterInk 才会把转写文本（绝不包含音频）发送给你配置的服务商。

## 30 秒演示

https://github.com/user-attachments/assets/b804b04b-4a71-44d5-a58f-7fbb56bf2e3c

<p align="center"><sub><strong>快速了解 UtterInk。</strong>本地听写、安全交付，以及同一句口语如何通过内置或自定义模式变成不同表达。</sub></p>

## 产品界面

<p align="center">
  <img src="docs/assets/screenshots/menu-idle.png" width="320" alt="UtterInk 菜单，包含开始听写、输出模式、历史记录和设置">
</p>

<p align="center"><sub><strong>紧凑菜单。</strong>开始听写、切换输出模式，或找回最近文本。</sub></p>

<p align="center">
  <img src="docs/assets/screenshots/recording-overlay.png" width="560" alt="UtterInk 录音悬浮条，包含计时、动态波形和停止按钮">
</p>

<p align="center"><sub><strong>录音悬浮条。</strong>实时显示波形和计时，但不会抢走当前输入框的键盘焦点。</sub></p>

_截图由隔离的假数据 UI 测试生成，不包含任何用户内容。_

## 功能

- **随时开始听写。** 默认快捷键是右 Option；也可自定义组合键，并选择“切换”或“按住说话”。
- **本地语音识别。** 停止录音后由 WhisperKit 在本机转写，提供“快速”“推荐”和“最佳质量”三档模型。
- **专注的录音界面。** 可选悬浮条会展示听写、处理、成功和可恢复错误状态，同时不会变成最前方的输入目标。
- **安全交付。** 可选带保护的“自动粘贴”或“仅复制”；无法确认原输入目标时，文字仍会保留，供复制或再次粘贴。
- **实用输出模式。** 默认 Raw，另有五种内置 AI 润色模式，也可创建和编辑自定义模式。
- **本地找回。** 历史记录最多保存 20 个纯文本会话，支持复制、再次粘贴、单条删除和清空历史。

## 快速开始

1. 从 [v0.1.0 Release](https://github.com/kthree0213/UtterInk/releases/tag/v0.1.0) 下载已签名并通过 Apple 公证的 `UtterInk-0.1.0-arm64.dmg`，打开后把 UtterInk 拖入“应用程序”。
2. 完成新手引导：允许麦克风权限；如需全局快捷键和自动粘贴，再允许辅助功能权限；然后选择识别语言和语音模型。
3. 建议首次选择 **Recommended（推荐）**（`small`，约 489 MB）并确认下载。未下载的模型只有在你确认后才会开始下载。
4. 把光标放进输入框，按一次**右 Option**开始说话，再按一次停止。默认行为是“切换”，可在**设置 → 快捷键**中修改。
5. 等待本地转写。开启“自动粘贴”后，UtterInk 会尝试把结果送回原输入框；若无法安全完成，可使用明确的“复制”恢复操作。

Raw 听写不需要 API Key。需要 AI 润色时，请继续阅读[可选 AI 润色](#可选-ai-润色)。

## 隐私摘要

- **本地 Whisper 转写。** UtterInk 只为当前会话录制短期本地 CAF，并在停止录音后通过 WhisperKit 在这台 Mac 上转写。
- **不会保存音频。** 音频不会进入历史记录，也不会发送给文本润色服务。常规清理流程会删除临时文件，启动及每次录音前还会清理由崩溃或断电遗留的孤立文件。APFS 的普通删除属于尽力清理，并不等同于可保证的安全擦除。
- **只保存文本的 20 个会话历史。** 历史记录默认开启，在 `~/Library/Application Support/UtterInk` 中最多保存 20 个纯文本会话，包括原始文本和最终文本。
- **可选文本外发。** Raw 模式不使用文本服务。可选的 OpenAI 兼容润色会把所选模型 ID、已保存的指令、原始转写文本，以及已配置时的授权凭据发送到设置中显示的主机，但绝不会发送音频。
- **凭据受保护。** 服务商 API Key 按配置存入 macOS Keychain（钥匙串），而不是普通设置或历史记录。
- **没有分析。没有云同步。** 当前源码没有分析或跟踪 SDK。诊断只包含允许清单中的运行字段，并且只有在你预览并选择保存位置后才会导出。

完整的数据边界与删除说明见[隐私政策](PRIVACY.md)和[隐私数据流](docs/privacy-data-flow.md)。

## 可选 AI 润色

Raw 默认启用，不需要服务商或凭据。内置选择如下：

| 模式 | 作用 | 会把转写文本发送给服务商吗？ |
| --- | --- | --- |
| **Raw** | 原样返回本地转写 | 不会 |
| **Clean Up** | 去除口头填充、修正标点，同时保留原意 | 会 |
| **AI Prompt** | 把口述想法整理成更清晰的 AI 提示词 | 会 |
| **Translate to English** | 直接输出英文翻译 | 会 |
| **Work Message** | 改写为简洁、专业的工作沟通 | 会 |
| **Classical Chinese** | 改写为文言文 | 会 |
| **Custom** | 使用你创建和编辑的指令 | 会 |

配置润色的步骤：

1. 打开**设置 → 服务商**并选择一个服务商模板；只有需要自行填写 OpenAI 兼容 Base URL 时才选择 **Custom**。
2. 输入 API Key，检查 UtterInk 显示的规范化目标主机，然后选择 **Test Key & Load Models**。远程主机必须使用 HTTPS；明文 HTTP 只允许显式选择这台 Mac 上的标准回环主机。
3. 从服务商返回的兼容模型中选择一个，再选择 **Save & Use**。API Key 会存入 macOS 钥匙串，不会写入普通设置、历史记录或诊断。
4. 打开**设置 → 输出模式**并选择内置或自定义模式。如果不希望任何转写文本离开这台 Mac，请保持 **Raw**。

发起润色请求时，UtterInk 会在 `POST /chat/completions` 请求中发送模型 ID、已保存的指令和原始转写文本；如配置了 API Key，则会把它作为 Bearer 凭据发送。音频绝不会发送。服务商和网络仍受其各自的隐私及数据保留政策约束。

## 语音模型

语音模型权重不包含在仓库或应用中。选择尚未下载的模型时，UtterInk 会先让你确认，并会标示本地已经可用的模型。

| 应用内名称 | 模型 ID | 目录标示大小（约） | 适合场景 |
| --- | --- | ---: | --- |
| **Fast（快速）** | `base` | 149 MB | 下载最小、最快开始使用 |
| **Recommended（推荐）** | `small` | 489 MB | 适合大多数用户的首选平衡档 |
| **Best Quality（最佳质量）** | `large-v3` | 3.1 GB | 可以接受更大磁盘占用时追求更高识别质量 |

模型会从固定的 Hugging Face revision 下载并缓存到 `~/Library/Application Support/UtterInk/huggingface`。仅当缓存模型未被选中、准备、加载或由活动操作占用时，才能在设置中删除。

## 系统要求

- macOS 14 部署目标
- 仅支持 Apple Silicon / arm64
- 首次下载所选语音模型和分词器时需要联网
- 文档所示源码流程使用 Xcode 26.4.1 build 17E202、Apple Swift 6.3.1 和 XcodeGen 2.45.4

所选模型缓存完成后，Raw 本地转写不需要联网；可选 AI 润色需要能够访问你配置的服务商。

## 安装发布版本

UtterInk v0.1.0 已作为 Developer ID 签名并通过 Apple 公证的 DMG 发布在 [GitHub Releases](https://github.com/kthree0213/UtterInk/releases/tag/v0.1.0)。

请同时下载 DMG 和 `SHA256SUMS`。将 `shasum -a 256 UtterInk-0.1.0-arm64.dmg` 的输出与 `SHA256SUMS` 中对应行进行比较；也可以下载全部五个 Release 文件，再运行发布说明中的完整校验命令。哈希不一致时请立即停止。校验通过后打开 DMG，并把 UtterInk 拖入“应用程序”。

语音模型不会打包进 DMG，首次使用时会另行下载。

## 权限

- **麦克风——录音必需。** 音频只用于本地转写。
- **辅助功能——仅做本地转写时可选，完整全局流程需要。** 它用于全局快捷键、精确目标校验和带保护的“自动粘贴”；不开启时仍可明确选择“复制”。

可在设置中检查权限状态。UtterInk 并不需要辅助功能权限才能单独完成本地转写。

## 历史记录与恢复

历史记录默认开启，在本机 `history-v1.json` 中保存最近 20 个会话的原始/最终文本，绝不保存音频。历史开启时，UtterInk 会在可选远程润色之前先保存原始转写，因此服务商或交付失败不会导致原文丢失。

关闭历史记录会立即阻止新的持久写入，并使已经在途的历史写入失效，但不会删除已保存的内容。请使用单条**删除**或**清空历史记录**移除它们。关闭历史期间产生的结果只保留在内存中，退出 UtterInk 后即消失。

“自动粘贴”会在内存中临时保存当前剪贴板快照，上限为 16 MiB，捕获窗口为 0.5 秒。仅当剪贴板未被改动时，UtterInk 才会尝试受保护恢复；系统恢复操作仍可能失败，且快照不会写入应用存储。`NSPasteboard` 不提供原子化的“比较并写入”或“比较并恢复”操作，因此在任一检查与后续操作之间的极小窗口中，另一项复制仍可能被覆盖。“仅复制”和明确的“复制”会有意替换剪贴板，不会恢复。如果无法安全完成交付，结果仍会保留供用户恢复。

## 从源码构建

使用 XcodeGen 2.45.4 生成项目，并把构建产物放在检出目录之外。子 shell 会在保留构建失败状态的同时清理临时目录：

```bash
(
  set -e
  test "$(xcodegen --version | sed 's/^Version: //')" = '2.45.4'
  xcodegen generate
  BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utterink-readme-build.XXXXXX")"
  trap 'status=$?; trap - EXIT; rm -rf -- "$BUILD_ROOT" || status=$?; exit "$status"' EXIT
  xcodebuild \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    CODE_SIGNING_ALLOWED=NO \
    build
)
```

也可以打开 `UtterInk.xcodeproj`，在 Xcode 中运行 `UtterInk` scheme。首次启动后，请在新手引导或设置中选择并下载语音模型。

## 测试

运行 Swift package 测试：

```bash
(
  set -e
  PACKAGE_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utterink-package-test.XXXXXX")"
  trap 'status=$?; trap - EXIT; rm -rf -- "$PACKAGE_TEST_ROOT" || status=$?; exit "$status"' EXIT
  swift test \
    --package-path Packages/UtterInkKit \
    --scratch-path "$PACKAGE_TEST_ROOT/UtterInkKit-build" \
    --disable-sandbox \
    --force-resolved-versions
)
```

运行不含 UI 自动化的 App 单元测试：

```bash
(
  set -e
  test "$(xcodegen --version | sed 's/^Version: //')" = '2.45.4'
  xcodegen generate
  APP_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utterink-app-test.XXXXXX")"
  trap 'status=$?; trap - EXIT; rm -rf -- "$APP_TEST_ROOT" || status=$?; exit "$status"' EXIT
  xcodebuild \
    -project UtterInk.xcodeproj \
    -scheme UtterInk \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$APP_TEST_ROOT/DerivedData" \
    -clonedSourcePackagesDirPath "$APP_TEST_ROOT/SourcePackages" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    test \
    -only-testing:UtterInkAppTests
)
```

运行仓库完整的本地验证，其中包含定向 UI 冒烟测试：

```bash
./Scripts/ci-local.sh
```

## 未签名构建

以上源码命令只会生成未签名的开发构建。它没有经过公证，也不用于再分发。正式签名版本只会发布在上方链接的 GitHub Releases 页面。

下方故障闭合的打包路径依赖已审核并提交的 `Config/ci-toolchain.json` 锁，其中记录了审核过的来源标识和哈希。贡献者无需 Apple 凭据即可运行同一验证路径；任何工具链或生成工程漂移都会以失败关闭：

```bash
(
  set -e
  trap 'status=$?; trap - EXIT; ./Scripts/clean-distribution-output.sh || status=$?; exit "$status"' EXIT
  ./Scripts/bootstrap-xcodegen.sh
  UTTERINK_EXPECTED_ORIGIN='https://github.com/kthree0213/UtterInk.git' \
    ./Scripts/ci-local.sh --unsigned-package-smoke
)
```

请让预期地址与另行审核过的规范 `origin` 逐字节一致；如果这个检出有意不配置远程仓库，则省略 `UTTERINK_EXPECTED_ORIGIN`。任何产物的名称都包含 `UNSIGNED-DO-NOT-DISTRIBUTE`，只能留在本地，并由退出清理删除。签名、公证、最终验证和发布属于互相独立的维护者阶段，详见[发布流程](docs/RELEASING.md)；运行上述命令不会授权其中任何操作。

## 当前限制

- 仅支持 Apple Silicon / arm64，没有 Intel 版本。
- 界面目前仅提供英语；语音识别语言可选“自动”或固定“英语”。
- 不支持实时转写，也不支持流式转写；转写在停止录音后开始。
- UtterInk 没有自动更新功能；后续版本需要从 GitHub Releases 手动安装。
- 不支持云同步；设置和历史记录保留在这台 Mac 上。
- 不内置 API Key；可选服务商需要用户提供凭据，显式配置的无密钥回环服务除外。
- 模型下载体积较大，在手动删除前会持续缓存，且没有自动清理机制。
- 音频清理和历史删除使用普通文件系统删除，不保证安全擦除。
- 单条历史记录从当前界面消失后，其持久删除仍可能失败；UtterInk 只会记录脱敏的本地诊断，该记录可能在重新启动后再次出现。
- 目标位置或剪贴板发生变化时，“自动粘贴”会中止或尝试上文所述的受保护恢复；系统恢复仍可能失败，但文本结果可从最近结果或历史视图取回。
- v0.1.0 的部署目标是 macOS 14，但干净机器发布验收是在 macOS 26 上完成；较早的受支持 macOS 版本没有接受同等级别的独立实体 Mac 验收。

## 贡献与安全

参与贡献前，请阅读[贡献指南](CONTRIBUTING.md)、[行为准则](CODE_OF_CONDUCT.md)和[商标政策](TRADEMARKS.md)。

请将疑似安全漏洞私下报告至 `swallowclever.k3@gmail.com`，并遵循[安全政策](SECURITY.md)。不要在公开 issue 中包含凭据、转写内容或其他敏感数据。该地址同时是获批准的行为准则执行联系人。

## 许可证

UtterInk 源代码采用 [Apache-2.0](LICENSE) 许可证，版权归 2026 kthree0213 所有。源码许可证不授予 UtterInk 名称、Logo、图标或其他品牌标识的使用权；详见 [TRADEMARKS.md](TRADEMARKS.md)。

依赖项许可证和运行时下载模型的声明记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；再分发时必须保留适用的 [NOTICE](NOTICE) 内容。
