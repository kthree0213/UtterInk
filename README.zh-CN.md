# UtterInk

UtterInk 是一款注重隐私的 macOS 菜单栏听写应用，可在本机把语音转成文本，并安全地将结果送到正在输入的位置。

[English](README.md)

## 品牌标识

![UtterInk 字标](Brand/wordmark-lockup.svg)

_品牌标识图，不是产品截图。_

## 隐私摘要

- **本地 Whisper 转写。** UtterInk 只为当前会话录制短期本地 CAF，并在停止录音后通过 WhisperKit 在这台 Mac 上转写。
- **不会保存音频。** 音频不会进入历史记录，也不会发送给文本润色服务。常规清理流程会删除临时文件，启动及每次录音前还会清理由崩溃或断电遗留的孤立文件。APFS 的普通删除属于尽力清理，并不等同于可保证的安全擦除。
- **只保存文本的 20 个会话历史。** 历史记录默认开启，在 `~/Library/Application Support/UtterInk` 中最多保存 20 个纯文本会话，包括原始文本和最终文本。
- **可选文本外发。** Raw 模式不使用文本服务。可选 OpenAI 兼容文本润色会把所选模型 ID、已保存的润色指令、原始转写文本，以及已配置时的授权凭据发送到设置中显示的主机，但绝不会发送音频。
- **凭据受保护。** 当前服务商 API 密钥按配置存入 macOS Keychain（钥匙串），而不是常规设置或历史记录。旧版明文凭据迁移失败时，UtterInk 会阻止使用并显示问题，不会把迁移视为完成。
- **产品数据留在本机。** 当前源码没有分析或跟踪 SDK，也不支持云同步。诊断仅包含允许清单中的运行字段，并且只有在用户预览并选择保存位置后才会导出。

完整的数据边界与删除说明见[隐私政策](PRIVACY.md)和[隐私数据流](docs/privacy-data-flow.md)。

## 功能

- 菜单栏控制，以及可选的悬浮录音窗口。
- 默认使用右 Option 键，也可自定义快捷键，并可选择“切换”或“按住说话”的触发方式。
- 通过 WhisperKit 进行本地 Whisper 语音识别，可选 `base`、`small` 和 `large-v3` 模型。
- 默认使用 Raw 输出，内置五种润色模式，也可配置自定义润色指令。
- 带剪贴板保护恢复的“自动粘贴”，或“仅复制”交付方式。
- 按会话恢复、复制、再次粘贴、删除和清空历史记录。
- 语音识别语言可选“自动”或固定“英语”。

## 系统要求

- macOS 14+
- 仅支持 Apple Silicon / arm64
- 文档所示源码流程使用 Xcode 26.4.1 build 17E202、Apple Swift 6.3.1 和 XcodeGen 2.45.4
- 首次下载所选语音模型和分词器时需要联网

语音模型权重不包含在仓库或应用中，而是在运行时从固定的 Hugging Face revision 下载并缓存到 `~/Library/Application Support/UtterInk/huggingface`。目录标示大小约为：`base` 149 MB、`small` 489 MB、`large-v3` 3.1 GB；仅当缓存模型未被选中、准备、加载或由活动操作占用时，才能在设置中删除。

## 安装发布版本

签名并经过 Apple 公证的版本只通过项目的
[GitHub Releases](https://github.com/kthree0213/UtterInk/releases) 页面分发。
如果该页面没有 DMG 文件，说明目前还没有发布可安装版本，请改用下方源码流程。

正式版本发布后，请同时下载 DMG 和 `SHA256SUMS`，按照发布说明校验哈希，
打开 DMG，再把 UtterInk 拖入“应用程序”。语音模型不会打包进 DMG，首次使用时会另行下载。

## 从源码构建

使用 XcodeGen 2.45.4 生成项目，并把构建产物放在仓库外。子 shell 会在保留构建失败状态的同时清理临时目录：

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

也可以打开 `UtterInk.xcodeproj`，在 Xcode 中运行 `UtterInk` scheme。首次启动后，请在引导页或设置中选择并下载语音模型。

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

以上源码命令只会生成未签名的开发构建。它没有经过公证，也不用于再分发。
正式签名版本（如有）只会发布在上方链接的 GitHub Releases 页面。

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

## 可选服务商设置

Raw 是默认模式，无需服务商或凭据即可使用。如需开启自定义文本润色：

1. 打开**设置 → 服务商**并选择一个服务商模板；只有需要自行填写 OpenAI 兼容基础 URL 时才选择**自定义**。
2. 输入 API 密钥，检查 UtterInk 显示的规范化目标主机，然后选择**测试密钥并加载模型**。远程主机必须使用 HTTPS；明文 HTTP 只允许显式选择这台 Mac 上的标准回环主机。
3. 从服务商返回的兼容模型中选择一个，再选择**保存并使用**。API 密钥会存入 macOS 钥匙串，不会写入普通设置、历史记录或诊断。
4. 打开**设置 → 输出模式**，选择 **Clean Up**、**AI Prompt**、**Translate to English**、**Work Message**、**Classical Chinese** 或自定义模式；如果不希望文本发送给服务商，请继续使用 **Raw**。

发起润色请求时，UtterInk 会在 `POST /chat/completions` 请求中发送模型 ID、已保存的指令和原始转写文本；如果配置中包含 API 密钥，则会将其作为 Bearer 凭据发送。音频绝不会发送。服务商和网络仍受其各自隐私及保留政策约束。

## 历史记录与恢复

历史记录默认开启，在本机 `history-v1.json` 中保存最近 20 个会话的原始/最终文本，绝不保存音频。历史开启时，UtterInk 会在可选远程润色之前先保存原始转写，因此服务商或交付失败不会导致原文丢失。

关闭历史记录会立即阻止新的持久写入，并使已在途的历史写入失效，但不会删除已经保存的内容。请使用单条**删除**或**清空历史记录**移除它们。关闭历史期间产生的结果仅保留在内存中，退出 UtterInk 后即消失。

“自动粘贴”会在内存中临时保存当前剪贴板快照，上限为 16 MiB，捕获窗口为 0.5 秒。仅当剪贴板未被改动时，UtterInk 才会尝试受保护恢复；系统恢复操作仍可能失败，且快照不会写入应用存储。`NSPasteboard` 不提供原子化的“比较并写入”或“比较并恢复”操作，因此在任一检查与后续操作之间的极小窗口中，另一项复制仍可能被覆盖。“仅复制”和显式“复制”会有意替换剪贴板，不会恢复。如果无法安全完成交付，结果仍会保留供用户恢复。

## 权限

- **麦克风——录音必需。** 音频用于本地转写。
- **辅助功能——可选。** 它用于精确目标校验和受保护的“自动粘贴”；不开启时，本地转写和显式“复制”仍可使用。

可在设置中检查权限状态。仅在本地转写并不要求辅助功能权限。

## 当前限制

- 仅支持 Apple Silicon / arm64。
- 界面目前仅提供英语；语音识别语言可选“自动”或固定“英语”。
- 不支持实时转录，也不支持流式转录；转写在停止录音后开始。
- 不支持自动更新；源码构建需要手动更新。
- 不支持云同步；设置和历史记录保留在这台 Mac 上。
- 不内置 API 密钥；可选服务商需要用户提供凭据，显式配置的无密钥回环服务除外。
- 模型下载体积较大，在手动删除前会持续缓存，且没有自动清理机制。
- 音频清理和历史删除使用普通文件系统删除，不保证安全擦除。
- 单条历史记录从当前界面消失后，其持久删除仍可能失败；UtterInk 只会记录脱敏的本地诊断，该记录可能在重新启动后再次出现。
- 目标位置或剪贴板发生变化时，“自动粘贴”会中止或尝试上文所述的受保护恢复；系统恢复仍可能失败，但文本结果可从最近结果或历史视图取回。
- 可安装版本（如有）会通过 GitHub Releases 手动发布；UtterInk 不支持自动更新。

## 贡献与安全

参与贡献前，请阅读[贡献指南](CONTRIBUTING.md)、[行为准则](CODE_OF_CONDUCT.md)和[商标政策](TRADEMARKS.md)。

请将疑似安全漏洞私下报告至 `swallowclever.k3@gmail.com`，并遵循[安全政策](SECURITY.md)。不要在公开 issue 中包含凭据、转写内容或其他敏感数据。该地址同时是获批准的行为准则执行联系人。

## 许可证

UtterInk 源代码采用 [Apache-2.0](LICENSE) 许可证，版权归 2026 kthree0213 所有。源码许可证不授予 UtterInk 名称、Logo、图标或其他品牌标识的使用权；详见 [TRADEMARKS.md](TRADEMARKS.md)。

依赖项许可证和运行时下载模型的声明记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；再分发时必须保留适用的 [NOTICE](NOTICE) 内容。
