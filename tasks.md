# TNT Phase 1 任务清单

> 版本基准：`package.json` 中的 `version` 字段。任务完成一项打一项。
> **验证状态**：ASR + LLM 流水线已通过 `test/data/test-01.m4a` 端到端测试（2026-04-22）

---

## P0 — 必须完成（可演示）

### 0. 项目初始化
- [x] **0.1** 创建 Swift Package 项目（`swift package init --type executable`）
- [x] **0.2** 配置 `Package.swift`：Swift 6.2，无外部 SPM 依赖
- [x] **0.3** 配置 XcodeGen `project.yml`，生成 `.xcodeproj`
- [x] **0.4** 创建 `Info.plist`：`NSMicrophoneUsageDescription`、`LSUIElement=YES` 菜单栏模式
- [x] **0.5** 配置 entitlements：`com.apple.security.device.audio-input`
- [x] **0.6** 创建 `docs/PRD.md`
- [x] **0.7** 验证 `swift build` 能通过编译 ✓ 已验证（2026-04-22）

### 1. 系统托盘 / 菜单栏
- [x] **1.1** 创建 `NSStatusBarButton`，显示托盘图标（程序化绘制麦克风图标）
- [x] **1.2** 实现菜单项：**关于 TNT**（显示版本号 + 简介）、**设置**、**退出**
- [x] **1.3** "关于"窗口：显示 1.0.0 版本和应用图标描述
- [x] **1.4** 点击托盘图标：弹出/收起菜单

### 2. 全局快捷键管理
- [x] **2.1** 研究默认快捷键：**右 Option 键**（`0x3B`，无冲突）
- [x] **2.2** 实现 `CGEventTap` 全局热键监听（keyDown → 录音，keyUp → 停止）
- [x] **2.3** 实现权限检查与引导（未授权时弹出系统偏好设置）
- [ ] **2.4** 快捷键冲突检测（检测是否与其他 App 热键冲突）
- [ ] **2.5** 设置界面：允许用户自定义快捷键（存储在 `UserDefaults`）

### 3. 模型预加载（App 启动时）
- [x] **3.1** 在 `AppDelegate.applicationDidFinishLaunching` 中启动模型加载流程
- [x] **3.2** `ASREngine`：Python/mlx-audio 调用，模型缓存避免重复加载
- [x] **3.3** `LLMRefiner`：Python/mlx_lm 调用，模型缓存避免重复加载
- [x] **3.4** 显示加载进度：在托盘图标变灰 + 提示文字
- [x] **3.5** 加载完成后记录 `modelsReady = true`，热键触发跳过加载延迟
- [ ] **3.6** 后台静默更新：定期检查模型版本，有新版本时后台下载替换

### 4. 音频录制
- [x] **4.1** 实现按下快捷键开始录音、松开停止录音（AVAudioEngine + installTap）
- [x] **4.2** 重采样到 16kHz 单声道（浮点线性插值）
- [x] **4.3** 录音状态回调：`onAudioBuffer` 将 float32 Data 传递给 ASR
- [x] **4.4** 临时 WAV 文件写入（NSTemporaryDirectory）

### 5. 模型下载与管理（配置化）
- [x] **5.1** 创建 `ModelManager.swift`：读取 `package.json` 中的 `models[].urls`，提供 `download(model:)` 接口
- [x] **5.2** 支持 HF Mirror 下载源：`HF_ENDPOINT=https://hf-mirror.com`
- [x] **5.3** 编写 `ASREngine.swift`：调用 Python 脚本，返回文字
- [x] **5.4** 验证模型可加载：Qwen3-ASR-0.6B-4bit 通过 mlx-audio 加载成功
- [x] **5.5** 验证 ASR 效果（test-01.m4a）：
      - ASR 输出：`这是一个测试音频。看看你能不能解析出来：数字是一二三四五六七八九十。`
      - 精度：✓ 数字识别为汉字，✓ 标点完整，✓ 1.62s 处理时间

### 6. 悬浮 Toast UI
- [x] **6.1** 创建 `ToastPanel`（`NSPanel` subclass，`nonactivatingPanel` + `borderless`）
- [x] **6.2** 实现"倾听中..."状态提示（白字黑色半透明背景）
- [x] **6.3** 实时文本显示（ASR interim results）
- [x] **6.4** 定位逻辑：获取焦点窗口 frame，Toast 显示在窗口下方居中
- [x] **6.5** 动画：淡入淡出（300ms opacity transition）

### 7. LLM 文本校正
- [x] **7.1** 编写 `LLMRefiner.swift`：调用 Python/mlx_lm 脚本
- [x] **7.2** 下载并验证 Qwen3-4B-4bit 模型（mlx-community/Qwen3-4B-4bit）
- [x] **7.3** 实现 Prompt 模板（Qwen3 chat template + `[/no_think]` 禁用思考模式）
- [x] **7.4** 验证校正效果（test-01.m4a）：
      - 输入：`数字是一二三四五六七八九十`
      - 输出：`1234567890`（中文数字转阿拉伯数字，✓ 正确）
      - 标点自动补全（✓ 句末添加句号）

### 8. 文字注入
- [x] **8.1** 实现焦点检测：使用 `AXUIElement` 获取当前焦点窗口和位置
- [x] **8.2** 实现四步注入：保存剪贴板 → 写入文字 → Cmd+V → 恢复剪贴板
- [x] **8.3** 中文输入法兼容：注入前发送 Escape 退出输入法
- [ ] **8.4** 端到端验证：需实际运行 App 测试

### 9. 设置界面
- [x] **9.1** SwiftUI TabView 实现：**通用** / **模型** / **高级** 三个标签页
- [ ] **9.2** 快捷键设置：热键录制器（类似 Alfred Hotkey Recorder）
- [x] **9.3** ASR 模型选择：本地 Qwen3-ASR-0.6B / mlx-whisper fallback
- [x] **9.4** LLM 开关：启用/禁用 LLM 校正（`UserDefaults.standard.set(llmEnabled)`）
- [ ] **9.5** 模型路径配置（高级设置）
- [x] **9.6** 模型下载管理：显示下载状态、下载按钮、删除本地副本
- [ ] **9.7** 首次运行引导：检测到模型未下载时弹出引导窗口

---

## P1 — 重要但 Phase 1 可跳过

- [ ] 截图 OCR（Vision 框架）—— Phase 2
- [ ] 剪贴板历史追踪（NSPasteboard 监听）—— Phase 2
- [ ] LLM 云端 API 兜底（OpenAI / 通义千问）—— Phase 2
- [ ] 波形显示（录音状态可视化）—— Phase 2
- [ ] VAD（语音活动检测，减少无效 ASR）—— Phase 2
- [ ] 模型自动后台更新（任务 3.6）—— Phase 2
- [ ] 快捷键冲突检测（任务 2.4）—— Phase 2
- [ ] 自定义快捷键设置（任务 2.5）—— Phase 2

---

## 验证记录（2026-04-22）

| 测试项 | 结果 | 备注 |
|--------|------|------|
| `swift build` | ✅ 通过 | 0 errors |
| `xcodegen generate` | ✅ 通过 | TNT.xcodeproj 生成 |
| Qwen3-ASR 加载 | ✅ 通过 | mlx-audio 0.4.2，模型 mlx-community/Qwen3-ASR-0.6B-4bit |
| ASR test-01.m4a | ✅ 通过 | `这是一个测试音频。看看你能不能解析出来：数字是一二三四五六七八九十。` |
| LLM 校正 test-01 | ✅ 通过 | 中文数字转阿拉伯数字：`1234567890` |
| HF Mirror | ✅ 通过 | `HF_ENDPOINT=https://hf-mirror.com` 正常下载 |
| Whisper-tiny fallback | ✅ 通过 | mlx-whisper 0.4.3 正常工作 |

---

## 版本对照

| 任务范围 | 目标版本 |
|---------|---------|
| P0 核心完成（未完成项见上方） | `1.0.0` |
| P0 + P1 全部完成 | `1.1.0` |
