# TNT 技术调研发现

> 记录构建 TNT 过程中验证过的关键技术发现。随项目迭代持续更新。

---

## 1. Qwen3-ASR-0.6B 本地运行验证

### 下载与路径
- 模型不随安装包分发，通过设置界面下载到 `~/Library/Application Support/TNT/Models/` 下
- MLX 专用版本（推荐）：`mlx-community/Qwen3-ASR-0.6B-4bit`（4-bit，~500MB，~1.5GB 内存）
- MLX 8-bit 版本：`mlx-community/Qwen3-ASR-0.6B-8bit`（更高精度，~2.5GB 内存）
- 下载源（配置化，支持双线路切换）：
  - HuggingFace：`https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit`
  - HF Mirror（国内）：`https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit`
  - ⚠️ 国内访问 HuggingFace 需设置 `HF_ENDPOINT=https://hf-mirror.com`

### MLX 集成方式（Python/mlx-audio）
```python
# scripts/asr_infer.py
from mlx_audio.stt.utils import load_model
from mlx_audio.stt.generate import generate_transcription

model = load_model("mlx-community/Qwen3-ASR-0.6B-4bit")
result = generate_transcription(
    model=model,
    audio="path/to/audio.wav",
    output_path="output.txt",
    format="txt",
    verbose=False,
)
print(result.text)  # "这是一个测试音频。看看你能不能解析出来：数字是一二三四五六七八九十。"
```

### 性能数据（Apple Silicon M2 Pro，实测）
- 模型加载：~3-5 秒（含首次下载缓存）
- ASR 推理（8.4 秒音频）：~0.7-1.6 秒
- 内存占用（4-bit）：~1.5GB 统一内存
- **结论：32GB Mac 可同时运行 ASR + LLM，无压力**

### 音频格式要求
- **mlx-audio 自动处理**：支持任意格式（m4a/mp3/wav），内部自动转 16kHz mono
- 输入：任意音频文件路径或 numpy array
- 输出：文字，带语言检测和时间戳

### 已验证的问题
- ⚠️ **首次下载模型耗时约 5-10 分钟（国内网络），设置界面需显示进度**
- ⚠️ mlx-audio 使用 HuggingFace Hub 下载，需设置 `HF_ENDPOINT=https://hf-mirror.com`（中国网络）
- ⚠️ mlx-audio 会将临时文件写入 `~/.cache/huggingface/hub/`

### 模型预加载策略（已验证）
```python
# Python 层：模型全局缓存
_cached_model = None

def get_model(model_id):
    global _cached_model
    if _cached_model is None:
        _cached_model = load_model(model_id)
    return _cached_model

# AppDelegate: Swift 层调用 Python 脚本，模型已在内存中
# 效果：热键按下 → 录音开始的延迟 < 100ms（模型已缓存）
```

**效果**：模型预加载后，热键按下 → ASR 完成的延迟 < 2s（含 0.7s 推理）。

---

## 2. VoiceInput 架构参考（最佳参考实现）

GitHub: [shibing624/VoiceInput](https://github.com/shibing624/VoiceInput)

### 核心实现细节
- **热键触发**：Fn 键或 右⌘，通过 `CGEventTap` 监听 `kCGHIDEventType` 的 `keyDown`/`keyUp`
- **文字注入**（四步法）：
  1. 保存当前剪贴板内容
  2. 将识别结果写入剪贴板
  3. `Cmd+V` 模拟按键注入
  4. 恢复原剪贴板内容
- **中文输入法兼容**：注入前通过 `CGEvent` 发送 `kCGEventKeyDown` + 特殊键码 `0x66`（Escape）退出当前输入法，注入后恢复
- **状态 HUD**：NSPanel 悬浮窗口，始终在最前，红色圆点指示录音状态

### 关键代码片段（已验证可用）
```swift
// 1. 退出输入法（注入前）
let escapeKey = CGEvent(keyboardEventSource: nil, virtualKey: 0x66, keyDown: true)
escapeKey?.post(tap: .cghidEventTap)

// 2. 注入文字（剪贴板法）
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(text, forType: .string)
let vKey = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
vKey?.flags = .maskCommand
vKey?.post(tap: .cghidEventTap)
```

---

## 3. CGEventTap 全局热键实现

### 权限要求
- 需要 `Accessibility` 权限（系统偏好设置 → 隐私与安全性 → 辅助功能）
- 需要 `Input Monitoring` 权限（系统偏好设置 → 隐私与安全性 → 输入监控）

### 代码模式
```swift
// 创建事件tap
let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(eventMask),
    callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
        // 处理按键
        return Unmanaged.passRetained(event)
    },
    userInfo: nil
) else {
    // 权限未授予
    return
}
```

### 快捷键配置推荐
- **默认**：右 Option 键（`0x3B` = `NSVentanaHotKeyRightOption`，无冲突）
- **备选**：双击 Right Command（双击 < 300ms 视为双击）
- **避免**：与 Raycast、Alfred 等常用工具的热键冲突

---

## 4. AVAudioEngine 音频录制

### 配置参数
```swift
let audioEngine = AVAudioEngine()
let inputNode = audioEngine.inputNode
let recordingFormat = inputNode.outputFormat(forBus: 0)

// 重采样到 16kHz（ASR 要求）
let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

// 安装 tap 录制 PCM
inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, _ in
    // buffer 即为音频数据，送入 ASR
    processAudioBuffer(buffer)
}
```

### 降噪策略
- **轻量降噪**（推荐 Phase 1）：使用 `AVAudioUnitEQ` 配置 `adaptiveNoiseGate`
- **深度降噪**（Phase 2）：使用 `speech enhancement` 模型（如 Silero VAD）
- **VAD（语音活动检测）**：使用 Silero Swift 在端侧判断是否有人说话，节省 ASR 调用

---

## 5. LLM 校正 Prompt 模板

### 核心 Prompt（已验证效果良好）
```
<|im_start|>system
你是一个专业的语音输入助手。只输出校正后的文字，不要添加任何前缀、解释或思考过程。
<|im_end|>
<|im_start|>user
[/no_think]
请对以下语音识别结果进行校正：
1. 修正同音字错误
2. 删除口吃、重复、填充词（如嗯、啊、那个、就是说、呃、这个这个）
3. 如果是中文数字（一二三四...），转为阿拉伯数字（1234...）
4. 添加合适的标点符号
5. 调整语序使表达更通顺
<|im_end|>
<|im_start|>assistant
```
**关键：[/no_think] 必须放在 user 消息末尾，用于禁用 Qwen3 的思考模式（Thinking Mode），
否则模型输出 `<think>...</think>` 标签内的推理过程。**

### 模型选择
- **mlx-community/Qwen3-4B-4bit**：最佳平衡点，~2.5GB 内存，校正速度 < 1 秒
- **mlx-community/Qwen3-4B-8bit**：更高精度，~5GB 内存
- 不推荐 3B 以下模型，校正质量不足

### 验证结果
- ASR 输出：`这是一个测试音频。看看你能不能解析出来：数字是一二三四五六七八九十。`
- LLM 校正后：`这是一个测试音频。看看你能不能解析出来：1234567890。`

---

## 6. macOS 权限体系

| 权限 | 用途 | 申请方式 |
|------|------|---------|
| 麦克风 | 音频录制 | `NSMicrophoneUsageDescription` in Info.plist |
| 辅助功能 | CGEventTap 注入 | `CGRequestAccessibilityEnabled()` 触发弹窗 |
| 输入监控 | 键盘事件监听 | `Input Monitoring` in entitlements |
| 屏幕录制 | 截图 OCR | `NSScreenCaptureUsageDescription` in Info.plist |

### 权限检查代码
```swift
func checkAccessibilityPermission() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}
```

---

## 7. 状态机设计

```
┌─────────────┐
│   Idle      │  ← 初始状态，菜单栏常驻
└──────┬──────┘
       │ 按下全局快捷键
       ▼
┌─────────────┐   录音中，实时 ASR   ┌──────────────┐
│  Recording  │ ─────────────────▶ │  Recognizing │
└─────────────┘                     └──────┬───────┘
       │ 松开快捷键                        │ LLM 校正
       ▼                                   ▼
┌─────────────┐                     ┌──────────────┐
│  Stopping   │ ─────────────────▶ │  Refining    │
└──────┬──────┘                     └──────┬───────┘
       │ 注入文字完成                        │ 完成
       ▼                                   ▼
┌─────────────┐                     ┌──────────────┐
│  Idle       │ ◀────────────────── │  Injecting   │
└─────────────┘                     └──────────────┘
```

---

## 8. Toast 悬浮窗口实现

使用 `NSPanel`（非活跃时仍可显示）：
```swift
let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
    styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
    backing: .buffered,
    defer: false
)
panel.level = .floating
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
panel.backgroundColor = NSColor.black.withAlphaComponent(0.7)
```

位置计算：通过 `AXUIElement` 获取当前焦点窗口的 frame，Toast 显示在其下方 20px 处。

---

## 9. 模型下载配置

> 模型不打包在安装包内，通过设置界面下载。下载链接存储在 `package.json` 的 `models[].urls` 字段。
> ⚠️ 国内用户需设置 `HF_ENDPOINT=https://hf-mirror.com`（在 Python 脚本和 Swift ModelManager 中设置）。

| 模型 | HuggingFace (MLX) | HF Mirror（国内） | 内存占用 |
|------|------------------|------------------|---------|
| Qwen3-ASR-0.6B-4bit | `mlx-community/Qwen3-ASR-0.6B-4bit` | `https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit` | ~1.5GB |
| Qwen3-ASR-0.6B-8bit | `mlx-community/Qwen3-ASR-0.6B-8bit` | `https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-8bit` | ~2.5GB |
| Qwen3-4B-4bit | `mlx-community/Qwen3-4B-4bit` | `https://hf-mirror.com/mlx-community/Qwen3-4B-4bit` | ~2.5GB |
| Qwen3-4B-8bit | `mlx-community/Qwen3-4B-8bit` | `https://hf-mirror.com/mlx-community/Qwen3-4B-8bit` | ~5GB |

**设置界面入口**：TNT 菜单栏 → 设置 → 模型标签页
- 显示每个模型的下载状态（未下载 / 下载中 / 已就绪）
- 下载按钮 + 进度条（百分比 + 实时速度）
- 删除本地副本（释放磁盘空间）
- 下载源切换（HuggingFace / ModelScope）
