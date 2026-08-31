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
                "solver. Your job is to rewrite the user's input as a different "
                "mathematically equivalent expression. For example, 90 + 10 can be" 
                "represented as $10 \\times 10$. Here input is equivalent to output"
                "Think internally using this procedure: "
                "identify the value or expression, choose an identity or "
                "operation appropriate for the requested level, substitute the user's "
                "input into that identity, and verify it remains equivalent. Do not "
                "show these steps. Never return the original input unchanged. Never "
                "return only the simplified numeric value. Return exactly one Markdown "
                "line in this format:\n"
                "**Final Representation:** `expression`\n"
                f"{level_instruction}"
            ),
        },
        # {
        #     "role": "user",
        #     "content": "Level: Highschool\nInput: 1 + 1",
        # },
        # {
        #     "role": "assistant",
        #     "content": "**Final Representation:** `(1 + 1) + 0`",
        # },
        # {
        #     "role": "user",
        #     "content": "Level: Undergraduate\nInput: 1 + 1",
        # },
        # {
        #     "role": "assistant",
        #     "content": "**Final Representation:** `(1 + 1)(\\sin^2\\theta + \\cos^2\\theta)`",
        # },
        # {
        #     "role": "user",
        #     "content": "Level: Masters\nInput: 1 + 1",
        # },
        # {
        #     "role": "assistant",
        #     "content": "**Final Representation:** `\\frac{\\partial}{\\partial z}\\left[z(1 + 1)\\right]`",
        # },
        # {
        #     "role": "user",
        #     "content": "Level: PhD\nInput: 1 + 1",
        # },
        # {
        #     "role": "assistant",
        #     "content": "**Final Representation:** `(1 + 1)\\sum_{n=0}^{\\infty}\\frac{0^n}{n!}`",
        # },
        # {
        #     "role": "user",
        #     "content": "Level: Undergraduate\nInput: x^2 + 2x + 1",
        # },
        # {
        #     "role": "assistant",
        #     "content": "**Final Representation:** `(x^2 + 2x + 1)(\\sin^2\\theta + \\cos^2\\theta)`",
        # },
        # {
        #     "role": "user",
        #     "content": (
        #         f"Level: {generation_level}\n"
        #         f"Input: {prompt}\n"
        #         "Return only the Markdown final representation line."
        #     ),
        # },
    ]


def _format_final_representation(text: str) -> str:
    text = text.strip()
    return text


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
