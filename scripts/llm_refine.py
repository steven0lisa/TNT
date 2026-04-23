#!/usr/bin/env python3
"""
LLM refinement script for TNT using Qwen3-4B via mlx_lm.
Falls back to rule-based text cleaning when model is unavailable.

Usage: python3 llm_refine.py <text>
Output: refined text (one line)

Local path: ~/.tnt/models/Qwen3-4B-4bit
"""
import sys
import os
import re

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

HAS_MLX_LM = False
try:
    import mlx_lm
    HAS_MLX_LM = True
except ImportError:
    pass

# Cached model
_cached_model = None
_cached_tokenizer = None

LOCAL_MODEL_PATH = os.path.expanduser("~/.tnt/models/Qwen3-4B-4bit")
REMOTE_MODEL_ID = "mlx-community/Qwen3-4B-4bit"

SYSTEM_PROMPT = "你是一个专业的语音输入助手。只输出校正后的文字，不要添加任何前缀、解释或思考过程。"
REFINE_REQUEST = """请对以下语音识别结果进行校正：
1. 修正同音字错误
2. 删除口吃、重复、填充词（如嗯、啊、那个、就是说、呃、这个这个、重复的字词）
3. 如果是中文数字（一二三四...），转为阿拉伯数字（1234...）
4. 添加合适的标点符号
5. 调整语序使表达更通顺[/no_think]"""


def get_llm_model():
    """Load and cache the LLM model from local path or remote."""
    global _cached_model, _cached_tokenizer
    if _cached_model is not None:
        return _cached_model, _cached_tokenizer

    # Prefer local model
    if os.path.isdir(LOCAL_MODEL_PATH) and any(
        f.endswith(".safetensors") for f in os.listdir(LOCAL_MODEL_PATH)
    ):
        model_id = LOCAL_MODEL_PATH
        print(f"[LLM] Loading local model: {model_id}", file=sys.stderr)
    else:
        model_id = REMOTE_MODEL_ID
        print(f"[LLM] Local model not found, loading from HF: {model_id}", file=sys.stderr)

    _cached_model, _cached_tokenizer = mlx_lm.load(model_id)
    print(f"[LLM] Model loaded", file=sys.stderr)
    return _cached_model, _cached_tokenizer


def refine_with_llm(text: str) -> str:
    """Refine text using Qwen3-4B via mlx_lm with thinking disabled."""
    model, tokenizer = get_llm_model()

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"语音识别原始结果：{text}\n\n{REFINE_REQUEST}"},
    ]

    prompt = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=True
    )

    response = mlx_lm.generate(
        model=model,
        tokenizer=tokenizer,
        prompt=prompt,
        max_tokens=512,
        verbose=False,
    )

    # Strip Qwen3 think tags (<think>...</think>)
    response = re.sub(r'<think>.*?</think>', '', response, flags=re.DOTALL).strip()
    return response


def refine_with_rules(text: str) -> str:
    """Rule-based text cleanup (fallback when LLM unavailable)."""
    fillers = ["嗯", "啊", "呃", "那个", "就是说", "然后", "就", "这个"]
    result = text
    for filler in fillers:
        result = result.replace(filler, "")

    # Fix common ASR errors
    replacements = {
        "带妈": "代码",
        "車子": "车子", "應": "应",
        "你們": "你们", "解釋": "解释",
        "出來": "出来", "過來": "过来",
        "應該": "应该", "來說": "来说",
    }
    for wrong, correct in replacements.items():
        result = result.replace(wrong, correct)

    result = re.sub(r"\s+", " ", result)
    result = result.strip()

    if result and result[-1] not in "。！？.!?，,":
        result += "。"

    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 llm_refine.py <text>", file=sys.stderr)
        sys.exit(1)

    text = sys.argv[1]
    text = text.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\")

    print(f"[LLM] Refining: {text[:50]}...", file=sys.stderr)

    if HAS_MLX_LM:
        result = refine_with_llm(text)
    else:
        print("[LLM] mlx_lm not available, using rule-based cleanup", file=sys.stderr)
        result = refine_with_rules(text)

    print(result)


if __name__ == "__main__":
    main()
