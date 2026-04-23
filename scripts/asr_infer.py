#!/usr/bin/env python3
"""
ASR inference script using Qwen3-ASR-0.6B via mlx-audio (MLX on Apple Silicon).

Usage: python3 asr_infer.py <audio_file>
Output: transcribed text (one line)

Model: mlx-community/Qwen3-ASR-0.6B-4bit (~500MB, 4-bit, ~1.5GB RAM)
Local path: ~/.tnt/models/Qwen3-ASR-0.6B
"""
import sys
import os

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

HAS_MLX_AUDIO = False
try:
    from mlx_audio.stt.utils import load_model
    from mlx_audio.stt.generate import generate_transcription
    HAS_MLX_AUDIO = True
except ImportError:
    pass

# Cached model instance (load once, use many times)
_cached_model = None
_cached_model_id = None

LOCAL_MODEL_PATH = os.path.expanduser("~/.tnt/models/Qwen3-ASR-0.6B")
REMOTE_MODEL_ID = "mlx-community/Qwen3-ASR-0.6B-4bit"


def get_model():
    """Load and cache the ASR model from local path or remote."""
    global _cached_model, _cached_model_id

    if _cached_model is not None:
        return _cached_model

    # Prefer local model
    if os.path.isdir(LOCAL_MODEL_PATH) and any(
        f.endswith(".safetensors") for f in os.listdir(LOCAL_MODEL_PATH)
    ):
        model_id = LOCAL_MODEL_PATH
        print(f"[ASR] Loading local model: {model_id}", file=sys.stderr)
    else:
        model_id = REMOTE_MODEL_ID
        print(f"[ASR] Local model not found, loading from HF: {model_id}", file=sys.stderr)

    _cached_model = load_model(model_id)
    _cached_model_id = model_id
    print(f"[ASR] Model loaded", file=sys.stderr)
    return _cached_model


def transcribe_with_qwen3(audio_path: str) -> str:
    """Transcribe audio using Qwen3-ASR-0.6B via mlx-audio."""
    import tempfile

    model = get_model()

    print(f"[ASR] Transcribing: {audio_path}", file=sys.stderr)

    result = generate_transcription(
        model=model,
        audio=audio_path,
        output_path=tempfile.mktemp(suffix=".txt"),
        format="txt",
        verbose=False,
    )

    text = result.text.strip() if result.text else ""
    print(f"[ASR] Done ({result.total_time:.1f}s): {text[:60]}", file=sys.stderr)
    return text


def transcribe_fallback(audio_path: str) -> str:
    """Fallback when mlx-audio is not available: use mlx-whisper."""
    try:
        import mlx_whisper
    except ImportError:
        return "ERROR: mlx-audio not installed. Run: pip install -U mlx-audio"

    print("[ASR] Falling back to mlx-whisper tiny", file=sys.stderr)

    import subprocess, tempfile
    wav = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    wav.close()
    subprocess.run([
        "ffmpeg", "-y", "-i", audio_path,
        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
        wav.name
    ], capture_output=True)

    result = mlx_whisper.transcribe(
        audio=wav.name,
        path_or_hf_repo="mlx-community/whisper-tiny",
        verbose=False,
    )
    os.unlink(wav.name)
    return result.get("text", "").strip()


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 asr_infer.py <audio_file>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    if not os.path.exists(audio_path):
        print(f"ERROR: File not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    print(f"[ASR] Processing: {audio_path}", file=sys.stderr)

    if HAS_MLX_AUDIO:
        text = transcribe_with_qwen3(audio_path)
    else:
        text = transcribe_fallback(audio_path)

    print(text)


if __name__ == "__main__":
    main()
