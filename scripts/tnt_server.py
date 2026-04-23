#!/usr/bin/env python3
"""
TNT Python HTTP Server — 预加载 ASR + LLM 模型，通过 HTTP API 提供服务。

Endpoints:
  POST /asr    { "audio_path": "/path/to/audio.wav" } -> { "text": "..." }
  POST /refine { "text": "..." }                       -> { "text": "..." }
  GET  /health                                      -> { "status": "ok", "asr_ready": bool, "llm_ready": bool }

启动时一次性加载模型，后续请求复用，避免每次 subprocess 启动的冷加载开销。
"""

import sys
import os
import json
import re
import tempfile
import traceback

# ---------------------------------------------------------------------------
# 环境 & 配置
# ---------------------------------------------------------------------------
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

PORT = int(os.environ.get("TNT_SERVER_PORT", "18765"))
LOCAL_ASR_PATH = os.path.expanduser("~/.tnt/models/Qwen3-ASR-0.6B")
REMOTE_ASR_ID = "mlx-community/Qwen3-ASR-0.6B-4bit"
LOCAL_LLM_PATH = os.path.expanduser("~/.tnt/models/Qwen3-4B-4bit")
REMOTE_LLM_ID = "mlx-community/Qwen3-4B-4bit"

# ---------------------------------------------------------------------------
# 模型加载状态
# ---------------------------------------------------------------------------
_asr_model = None
_llm_model = None
_llm_tokenizer = None

HAS_MLX_AUDIO = False
HAS_MLX_LM = False

# ---------------------------------------------------------------------------
# 加载 mlx-audio
# ---------------------------------------------------------------------------
try:
    from mlx_audio.stt.utils import load_model as load_asr_model
    from mlx_audio.stt.generate import generate_transcription
    HAS_MLX_AUDIO = True
except ImportError:
    load_asr_model = None
    generate_transcription = None

# ---------------------------------------------------------------------------
# 加载 mlx-lm
# ---------------------------------------------------------------------------
try:
    import mlx_lm
    HAS_MLX_LM = True
except ImportError:
    mlx_lm = None

# ---------------------------------------------------------------------------
# LLM Prompt
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = "你是一个专业的语音输入助手。只输出校正后的文字，不要添加任何前缀、解释或思考过程。"
REFINE_REQUEST = """请对以下语音识别结果进行校正：
1. 修正同音字错误
2. 删除口吃、重复、填充词（如嗯、啊、那个、就是说、呃、这个这个、重复的字词）
3. 如果是中文数字（一二三四...），转为阿拉伯数字（1234...）
4. 添加合适的标点符号
5. 调整语序使表达更通顺[/no_think]"""

# ---------------------------------------------------------------------------
# 模型初始化
# ---------------------------------------------------------------------------
def init_models():
    """在服务器启动时预加载 ASR 和 LLM 模型。"""
    global _asr_model, _llm_model, _llm_tokenizer

    # ---- ASR ----
    if HAS_MLX_AUDIO:
        if os.path.isdir(LOCAL_ASR_PATH) and any(
            f.endswith(".safetensors") for f in os.listdir(LOCAL_ASR_PATH)
        ):
            asr_id = LOCAL_ASR_PATH
            print(f"[Server] Loading ASR from local: {asr_id}", file=sys.stderr)
        else:
            asr_id = REMOTE_ASR_ID
            print(f"[Server] Loading ASR from HuggingFace: {asr_id}", file=sys.stderr)

        try:
            _asr_model = load_asr_model(asr_id)
            print("[Server] ASR model loaded.", file=sys.stderr)
        except Exception as e:
            print(f"[Server] ASR load failed: {e}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
    else:
        print("[Server] mlx-audio not available, ASR disabled.", file=sys.stderr)

    # ---- LLM ----
    if HAS_MLX_LM:
        if os.path.isdir(LOCAL_LLM_PATH) and any(
            f.endswith(".safetensors") for f in os.listdir(LOCAL_LLM_PATH)
        ):
            llm_id = LOCAL_LLM_PATH
            print(f"[Server] Loading LLM from local: {llm_id}", file=sys.stderr)
        else:
            llm_id = REMOTE_LLM_ID
            print(f"[Server] Loading LLM from HuggingFace: {llm_id}", file=sys.stderr)

        try:
            _llm_model, _llm_tokenizer = mlx_lm.load(llm_id)
            print("[Server] LLM model loaded.", file=sys.stderr)
        except Exception as e:
            print(f"[Server] LLM load failed: {e}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
    else:
        print("[Server] mlx-lm not available, LLM disabled.", file=sys.stderr)


# ---------------------------------------------------------------------------
# 业务逻辑
# ---------------------------------------------------------------------------
def do_asr(audio_path: str) -> str:
    """执行 ASR 转录。"""
    if not HAS_MLX_AUDIO or _asr_model is None:
        raise RuntimeError("ASR model not available")

    if not os.path.exists(audio_path):
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    result = generate_transcription(
        model=_asr_model,
        audio=audio_path,
        output_path=tempfile.mktemp(suffix=".txt"),
        format="txt",
        verbose=False,
    )
    text = result.text.strip() if result.text else ""
    print(f"[Server] ASR done ({result.total_time:.1f}s): {text[:60]}", file=sys.stderr)
    return text


def do_refine(text: str) -> str:
    """执行 LLM 文本校正。"""
    if not HAS_MLX_LM or _llm_model is None or _llm_tokenizer is None:
        raise RuntimeError("LLM model not available")

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"语音识别原始结果：{text}\n\n{REFINE_REQUEST}"},
    ]

    prompt = _llm_tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )

    response = mlx_lm.generate(
        model=_llm_model,
        tokenizer=_llm_tokenizer,
        prompt=prompt,
        max_tokens=512,
        verbose=False,
    )

    # 去除 <think> 标签
    response = re.sub(r"<think>.*?</think>", "", response, flags=re.DOTALL).strip()
    print(f"[Server] LLM done: {response[:60]}", file=sys.stderr)
    return response


# ---------------------------------------------------------------------------
# HTTP 服务器 (标准库实现，零额外依赖)
# ---------------------------------------------------------------------------
from http.server import HTTPServer, BaseHTTPRequestHandler


class TNTHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # 关闭默认访问日志，减少干扰
        pass

    def _send_json(self, status: int, data: dict):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "asr_ready": HAS_MLX_AUDIO and _asr_model is not None,
                "llm_ready": HAS_MLX_LM and _llm_model is not None,
            })
        else:
            self._send_json(404, {"error": "Not found"})

    def do_POST(self):
        # 读取请求体
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")

        try:
            req = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._send_json(400, {"error": "Invalid JSON"})
            return

        try:
            if self.path == "/asr":
                audio_path = req.get("audio_path", "")
                if not audio_path:
                    self._send_json(400, {"error": "Missing audio_path"})
                    return
                text = do_asr(audio_path)
                self._send_json(200, {"text": text})

            elif self.path == "/refine":
                text = req.get("text", "")
                if not text:
                    self._send_json(400, {"error": "Missing text"})
                    return
                refined = do_refine(text)
                self._send_json(200, {"text": refined})

            else:
                self._send_json(404, {"error": "Not found"})

        except Exception as e:
            err_msg = str(e)
            print(f"[Server] ERROR: {err_msg}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            self._send_json(500, {"error": err_msg})


def main():
    print(f"[Server] Starting TNT server on port {PORT}...", file=sys.stderr)
    init_models()

    server = HTTPServer(("127.0.0.1", PORT), TNTHandler)
    print(f"[Server] Ready on http://127.0.0.1:{PORT}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[Server] Shutting down.", file=sys.stderr)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
