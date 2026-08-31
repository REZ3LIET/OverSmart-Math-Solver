from functools import lru_cache
import os
import resource
import time


DEFAULT_MODEL_NAME = os.getenv(
    "OSMS_MODEL_NAME",
    "unsloth/Qwen2.5-Math-1.5B-Instruct-bnb-4bit",
)

LEVEL_INSTRUCTIONS = {
    "Highschool": "Use basic arithmetic or algebra only.",
    "Undergraduate": "Use trigonometry or single-variable calculus.",
    "Masters": "Use advanced trigonometry, multivariable calculus, or partial derivatives.",
    "Graduate": "Use advanced trigonometry, multivariable calculus, or partial derivatives.",
    "PhD": "Use advanced mathematical machinery such as Lagrangians, Taylor series, limits, or series expansions.",
}


@lru_cache(maxsize=1)
def _load_model(model_name: str = DEFAULT_MODEL_NAME):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(
        model_name,
        trust_remote_code=True,
    )
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
        device_map="auto" if torch.cuda.is_available() else None,
        low_cpu_mem_usage=True,
        trust_remote_code=True,
    )
    if not torch.cuda.is_available():
        model.to("cpu")
    model.eval()
    return model, tokenizer


def _model_input_device(model):
    if hasattr(model, "hf_device_map") and model.hf_device_map:
        for device in model.hf_device_map.values():
            if device not in ("cpu", "disk"):
                return device
    return next(model.parameters()).device


def _build_messages(prompt: str, generation_level: str):
    level_instruction = LEVEL_INSTRUCTIONS.get(
        generation_level,
        LEVEL_INSTRUCTIONS["Highschool"],
    )
    return [
        {
            "role": "system",
            "content": (
                "You are a mathematical representation generator, not a step-by-step "
                "solver. Rewrite the user's math input as a different but "
                "mathematically equivalent expression. Do not simplify the input to a "
                "bare final value. For example, if the input is 1 + 1, do not answer "
                "with only 2; answer with another expression equivalent to 2. Return "
                "only one final answer in Markdown using this exact format:\n"
                "**Final Representation:** `expression`\n"
                "Do not include explanations, steps, boxed answers, headings, or extra "
                f"text. {level_instruction}"
            ),
        },
        {
            "role": "user",
            "content": (
                f"Create one {generation_level} representation equivalent to this "
                f"input, but do not return the simplified value alone: {prompt}"
            ),
        },
    ]


def _format_final_representation(text: str) -> str:
    text = text.strip()
    marker = "**Final Representation:**"
    if marker in text:
        text = text.split(marker, 1)[1].strip()
    elif "Final Representation:" in text:
        text = text.split("Final Representation:", 1)[1].strip()
    elif "final answer is:" in text.lower():
        text = text.rsplit(":", 1)[-1].strip()

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    text = lines[-1] if lines else text
    text = text.replace("\\boxed{", "").replace("}", "")
    text = text.strip("`[] .")
    return f"**Final Representation:** `{text}`" if text else ""


def generate_math_representation(
    prompt: str,
    generation_level: str,
    max_new_tokens: int,
    temperature: float,
) -> tuple[str, dict[str, float | int | str | None]]:
    import torch

    started_at = time.perf_counter()
    model, tokenizer = _load_model()
    load_ready_at = time.perf_counter()
    messages = _build_messages(prompt, generation_level)
    device = _model_input_device(model)

    if hasattr(tokenizer, "apply_chat_template") and tokenizer.chat_template:
        text = tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            tokenize=False,
        )
    else:
        text = "\n".join(f"{m['role']}: {m['content']}" for m in messages) + "\nassistant:"

    model_inputs = tokenizer(text, return_tensors="pt")
    model_inputs = {key: value.to(device) for key, value in model_inputs.items()}
    input_ids = model_inputs["input_ids"]

    prompt_tokens = int(input_ids.shape[-1])
    do_sample = temperature > 0
    if torch.cuda.is_available():
        try:
            torch.cuda.reset_peak_memory_stats()
        except RuntimeError:
            pass

    generation_started_at = time.perf_counter()
    pad_token_id = tokenizer.pad_token_id
    if pad_token_id is None:
        pad_token_id = tokenizer.eos_token_id

    generation_kwargs = {
        **model_inputs,
        "max_new_tokens": int(max_new_tokens),
        "do_sample": do_sample,
        "use_cache": True,
    }
    if pad_token_id is not None:
        generation_kwargs["pad_token_id"] = pad_token_id

    if do_sample:
        generation_kwargs["temperature"] = float(temperature)

    with torch.inference_mode():
        output_ids = model.generate(**generation_kwargs)

    generated_ids = output_ids[0, input_ids.shape[-1]:]
    finished_at = time.perf_counter()
    generated_tokens = int(generated_ids.shape[-1])
    response_time = finished_at - started_at
    generation_time = finished_at - generation_started_at
    peak_rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024

    gpu_peak_mb = None
    if torch.cuda.is_available():
        try:
            gpu_peak_mb = torch.cuda.max_memory_allocated() / (1024 * 1024)
        except RuntimeError:
            gpu_peak_mb = None

    metrics = {
        "model": DEFAULT_MODEL_NAME,
        "response_time_s": response_time,
        "model_ready_time_s": load_ready_at - started_at,
        "generation_time_s": generation_time,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "tokens_per_s": generated_tokens / generation_time if generation_time else 0.0,
        "peak_rss_mb": peak_rss_mb,
        "gpu_peak_allocated_mb": gpu_peak_mb,
    }
    response = tokenizer.decode(generated_ids, skip_special_tokens=True)
    return _format_final_representation(response), metrics
