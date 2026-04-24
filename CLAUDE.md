# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

TNT (Touch and Talk) 是一个 macOS 全局语音输入法。按住快捷键 (Option+Control+Command) 说话，松开后自动完成 ASR 识别 -> LLM 文本校正 -> 文字注入到输入焦点。所有 AI 推理在本地完成，使用 MLX 框架在 Apple Silicon 上运行。

## 常用命令

```bash
# 构建 (SPM)
swift build

# 通过 XcodeGen 生成 Xcode 项目后用 Xcode 构建
xcodegen generate
# 然后在 Xcode 中打开 TNT.xcodeproj

# 直接运行
swift run

# 运行 LLM 测试 (需要编译完整项目)
# 见 test/test_llm.swift
```

## 构建依赖

- macOS 14.0+ (Sonoma)
- Xcode 16+
- Swift 6.2 (严格并发模式 `SWIFT_STRICT_CONCURRENCY: complete`)
- Apple Silicon Mac (MLX 框架要求)

**SPM 依赖** (`Package.swift`):
- `mlx-swift` 0.31.3+ — Apple MLX 框架 Swift 绑定
- `mlx-swift-lm` 3.31.3+ — MLX 上的 LLM 加载与推理
- `swift-transformers` 1.3.0+ — HuggingFace tokenizer

**模型文件**: 不随安装包分发，存储在 `~/.tnt/models/` 下。模型配置信息在 `package.json` 的 `models` 字段中。

## 架构总览

### 核心数据流

```
Option+Ctrl+Cmd 按下
  -> HotkeyManager (CGEventTap 检测 flagsChanged)
  -> AudioRecorder.start() (AVAudioEngine, 重采样到 16kHz mono)
  -> [并行] ScreenCapture + PaddleOCREngine (可选)
  -> AudioRecorder.stop()
  -> AudioPostProcessor (音量归一化 + 静音裁剪)
  -> ASREngine.transcribe() (Apple SFSpeechRecognizer, 本地)
  -> LLMRefiner.refine() (Qwen3-4B via mlx-swift-lm, 本地 MLX)
  -> FocusManager.inject() (剪贴板 + Cmd+V, 先发 Escape 退出输入法)
```

### 状态机 (AppState/AppMode)

`idle -> recording -> recognizing -> refining -> injecting -> idle`

`AppDelegate` 持有全部核心单例的引用并通过 `AppMode` 驱动状态转换。所有 UI 更新在 `@MainActor` 上执行。

### 源码结构 (Sources/)

| 目录 | 职责 | 关键类 |
|------|------|--------|
| `App/` | 入口、生命周期、全局状态 | `AppDelegate`, `AppState`, `StatusBarController`, `main.swift` |
| `ASR/` | 语音识别 | `ASREngine` (Apple SFSpeechRecognizer), `MockASREngine` |
| `LLM/` | LLM 文本校正 | `LLMRefiner` (mlx-swift-lm), `LocalDownloader`, `TokenizerBridge`, `MockLLMRefiner` |
| `Model/` | 模型管理 + PaddleOCR-VL 推理 | `ModelManager`, `ModelDownloader`, `Configuration`, `PaddleOCRVLModel`, `PaddleOCRVLPipeline`, `LanguageModel`, `VisionEncoder`, `MultiModalProjector`, `ImageProcessor`, `Generator` |
| `Audio/` | 音频录制与后处理 | `AudioRecorder`, `AudioPostProcessor` |
| `Hotkey/` | 全局热键监听 | `HotkeyManager` (CGEventTap, flagsChanged 检测组合键) |
| `Focus/` | 输入焦点检测与文字注入 | `FocusManager` (AXUIElement + 剪贴板注入) |
| `UI/` | Toast 悬浮窗、设置界面 | `ToastWindow` (NSPanel), `SettingsView` (SwiftUI TabView) |

### 关键设计决策

**1. 热键机制**: 使用 `CGEventTap` 监听 `flagsChanged` 事件检测 Option+Control+Command 组合键的按下/松开，而非监听单个按键的 keyDown/keyUp。组合键中的 modifier 按键事件会被拦截(suppress)以防止触发系统快捷键。

**2. ASR 引擎**: 当前使用 Apple `SFSpeechRecognizer`（系统自带，无需下载额外模型）。早期版本通过 Python 脚本调用 `mlx-audio` 加载 Qwen3-ASR，已迁移为原生 Apple Speech 框架。

**3. LLM 推理**: 使用 `mlx-swift-lm` 的 `ModelContainer` 加载 Qwen3-4B-4bit 模型。自定义了 `LocalDownloader` 和 `LocalTokenizerLoader` 以支持从本地 `~/.tnt/models/` 目录加载。通过 `enable_thinking: false` 和 `[/no_think]` 禁用 Qwen3 的思考模式，并用 `filterThinkTags()` 正则过滤残留的 `<think/>` 标签。

**4. 文字注入**: 四步法：保存剪贴板 -> 写入文字 -> 模拟 Cmd+V -> 恢复剪贴板。注入前发送虚拟键码 `0x66` 退出中文输入法，避免与输入法冲突。

**5. OCR (PaddleOCR-VL)**: 完整的 Swift 原生实现，包含 Vision Encoder (NaViT)、Multi-Modal Projector、ERNIE Language Model、自实现的 KVCache 和 RoPE。支持固定分辨率(448x448)和动态分辨率两种模式。录音时异步截图 + OCR，将屏幕文字作为 LLM 上下文辅助校正专有名词。

**6. 模型下载**: `ModelDownloader` 通过 `hf-mirror.com` API 获取文件列表，流式下载 safetensors 文件到 `~/.tnt/models/`。支持断点续传（检查已有文件大小跳过已下载文件）。

**7. 并发模型**: 大量使用 `@unchecked Sendable` + `NSLock` 组合（而非 actor），因为需要与 CGEventTap 回调和 AVAudioEngine tap 等基于回调的 C API 交互。单例模式贯穿全局 (`ASREngine.shared`, `LLMRefiner.shared`, `ModelManager.shared` 等)。

## 系统权限要求

- **辅助功能** — CGEventTap 热键监听 + 文字注入 (必须)
- **麦克风** — 音频录制 (必须)
- **语音识别** — SFSpeechRecognizer (必须)
- **屏幕录制** — OCR 截图识别 (可选)

Info.plist 中 `LSUIElement=true` 表示不显示 Dock 图标，仅菜单栏常驻。

## 配置与模型管理

- `VERSION`: 唯一版本号来源，三文件同步（VERSION → package.json → project.yml）
- `package.json`: 版本号 + 模型配置 (HuggingFace/ModelScope 双源 URL)
- `project.yml`: XcodeGen 项目配置
- `UserDefaults`: 用户偏好 (快捷键选择、ASR/LLM 模型选择)

模型存储路径: `~/.tnt/models/Qwen3-4B-4bit/`, `~/.tnt/models/Qwen3-ASR-0.6B/` 等。

## 发布流程

版本号统一由 `VERSION` 文件管理，通过脚本自动同步到 `package.json` 和 `project.yml`。

### 使用 `/release` 命令发布（推荐）

直接使用 Claude Code 的 `/release` 命令，自动完成：生成 release note → 升级版本号 → 提交 → 打 tag → 推送触发 GitHub Actions。

### 手动发布

```bash
# 1. 升级版本号（自动更新 VERSION、package.json、project.yml）
./scripts/bump-version.sh patch   # 1.1.0 → 1.1.1（修订版）
./scripts/bump-version.sh minor   # 1.1.0 → 1.2.0（次版本）
./scripts/bump-version.sh major   # 1.1.0 → 2.0.0（主版本）

# 2. 提交并打 tag
git add -A && git commit -m 'chore: bump version to x.y.z'
git tag vx.y.z

# 3. 推送（触发 GitHub Actions 自动构建 DMG 并创建 Release）
git push origin main --tags
```

### CI/CD

GitHub Actions workflow (`.github/workflows/release.yml`) 在 `v*` tag 推送时自动：
- 在 macOS-15 runner 上用 Xcode 16 构建 Release 版本
- Ad-hoc 签名（防止 Gatekeeper "damaged" 错误）
- 打包为 DMG 文件
- 创建 GitHub Release 并上传 DMG

用户在设置页的"检查更新"按钮会查询 GitHub Releases API，发现新版本后可一键下载 DMG 安装。首次打开需右键 → 打开。

## 测试

当前测试基础设施较少。`test/` 目录下有 `test_llm.swift`（需要编译完整项目才能运行）和 `test/data/` 下的测试音频文件。大部分验证通过手动端到端测试完成（按快捷键说话 -> 检查输出文字）。

## 编码注意事项

- Swift 6.2 严格并发模式下，新的跨线程访问需要正确标注 `Sendable` 或使用 `@MainActor`
- `AppDelegate` 中所有 UI 操作都通过 `Task { @MainActor in }` 包裹
- `LLMRefiner` 和 `PaddleOCREngine` 使用 `NSLock` 保护 `modelContainer`/`pipeline` 的读写
- TNTLog 是全局日志工具（info/error/warning/debug 级别），在各模块中广泛使用
- `ModelManagerWrapper` 是 `ModelManager` 的 `@MainActor` + `@Published` 包装，供 SwiftUI 视图使用
