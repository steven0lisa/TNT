# TNT — Touch and Talk

> 基于全局快捷键的智能语音输入法，灵感源自老罗的 TNT 工作站。

## 概念

TNT（全称 Touch and Talk）是一个运行在 macOS 上的全局语音输入工具。无需切换输入法——按下全局快捷键，开始说话，松开即完成输入。

## 核心流程

```
用户按下快捷键
    │
    ├─→ 查找当前输入焦点（CGEventTap）
    ├─→ 显示悬浮 Toast（"倾听中..."）
    ├─→ 开始录音（AVAudioEngine）
    └─→ 实时 ASR 流式转写（Qwen3-ASR-0.6B MLX）
            │ 显示在 Toast 中
            ▼
用户松开快捷键
    │
    ├─→ 停止录音
    ├─→ 全量 ASR 结果 → LLM 校正（Qwen3-4B-4bit MLX）
    │       └─→ 删口水词、纠错、通顺化
    └─→ 提交文字到输入焦点（辅助功能 API）
```

## 技术栈

| 层级 | 技术 |
|------|------|
| 语言 | Swift 6.2 |
| UI | SwiftUI + 菜单栏应用 |
| ASR | Qwen3-ASR-0.6B（MLX 框架，Apple Silicon 加速） |
| LLM 校正 | Qwen3-4B-4bit（MLX 框架） |
| 热键监听 | CGEventTap（全局事件钩子） |
| 音频采集 | AVAudioEngine |
| 文字注入 | CGEvent / 剪贴板 + Cmd+V |

## 项目结构

```
TNT/
├── Sources/
│   ├── App/           # 入口、菜单栏、应用生命周期
│   ├── Audio/         # 音频录制、降噪
│   ├── ASR/           # Qwen3-ASR MLX 推理封装
│   ├── LLM/           # Qwen3 LLM 校正封装
│   ├── Hotkey/        # CGEventTap 全局热键
│   ├── Focus/         # 输入焦点检测与文字注入
│   └── UI/            # Toast、悬浮层、设置界面
├── Resources/
│   └── Assets.xcassets
├── docs/
│   └── PRD.md         # 产品需求文档
├── package.json       # 版本管理 + 模型下载链接配置
├── findings.md        # 技术调研发现
└── tasks.md           # 任务清单
```

## Phase 1 功能范围

- [ ] 菜单栏 App（托盘图标 + About / Settings / Quit）
- [ ] 全局快捷键管理与监听（CGEventTap）
- [ ] 音频录制与降噪（AVAudioEngine + AVAudioPCMBuffer）
- [ ] Qwen3-ASR-0.6B 本地推理（MLX）
- [ ] 悬浮 Toast UI（显示"倾听中..."和实时识别结果）
- [ ] LLM 文本校正（Qwen3-4B-4bit MLX）
- [ ] 文字注入到输入焦点
- [ ] 快捷键配置界面

## 快速开始

### 前置条件

- macOS 13+（Ventura）
- Apple Silicon Mac
- 32GB+ 统一内存（推荐）
- Xcode 16+

### 编译运行

```bash
# 克隆项目
cd TNT

# 构建
swift build

# 运行
swift run
```

### 模型下载（首次运行）

模型不随安装包分发，首次运行 TNT 时：
1. 弹出引导窗口，提示下载 ASR + LLM 模型
2. 或前往：菜单栏 → 设置 → 模型 → 下载

支持双源切换（HuggingFace 默认 / ModelScope 国内加速）。

### 权限

首次运行需要授权以下权限：
- **麦克风**（音频录制）
- **辅助功能**（全局热键 + 文字注入）
- **屏幕录制**（Phase 2 截图 OCR）

## 版本管理

版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)：
`major.minor.patch`

当前版本记录在 `package.json`，每次发布前递增 patch 版本。

## License

MIT
