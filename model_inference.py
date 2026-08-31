from functools import lru_cache
import os
import re
import resource
import time


try:
    import spaces
except ImportError:
    spaces = None


DEFAULT_MODEL_NAME = os.getenv(
    "OSMS_MODEL_NAME",
    "unsloth/Qwen2.5-Coder-3B-Instruct-bnb-4bit",
)
REMOTE_MODEL_NAME = os.getenv("OSMS_REMOTE_MODEL_NAME", "openai/gpt-oss-20b")

LEVEL_INSTRUCTIONS = {
    "Highschool": "Use only basic algebra.",
    "Undergraduate": "Use simple trigonometry and/or calculus.",
    "Masters": "Use only higher order calculus and/or partial derivatives.",
    "PhD": (
        "Use only advanced mathematical machinery such as Lagrangians, "
        "Taylor series, limits, or series expansions."
    ),
}


def _gpu(fn):
    """Capability for non-hf runs"""
    if spaces is None:
        return fn
    return spaces.GPU(fn)


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
            "role": "user",
            "content": (
                "Just for fun experiments, write a complicated math expression "
                f"using this instruction: {level_instruction} "
                f"The result must be the same as: {prompt}. Think step-wise to answer.\n"
                "Return only the final expression for fun in the format below:\n"
                "Expression: $${latex expression}$$"
            ),
        },
    ]


def _extract_final_expression(text: str) -> str:
    text = text.strip()
    if not text:
        return ""

    patterns = [
        r"Expression:\s*\${1,2}(.+?)\${1,2}",
        r"\*\*Final Representation:\*\*\s*`([^`]+)`",
        r"Final Representation:\s*`([^`]+)`",
        r"Final Representation:\s*(.+)",
        r"final answer is:\s*(.+)",
        r"answer is:\s*(.+)",
        r"\\boxed\{([^{}]+)\}",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE | re.DOTALL)
        if match:
            return _clean_expression(match.group(1))

    fenced_match = re.search(r"```(?:\w+)?\s*(.*?)\s*```", text, flags=re.DOTALL)
    if fenced_match:
        return _clean_expression(fenced_match.group(1))

    inline_code_matches = re.findall(r"`([^`]+)`", text)
    if inline_code_matches:
        return _clean_expression(inline_code_matches[-1])

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return _clean_expression(lines[-1] if lines else text)


def _to_display_math(expression: str) -> str:
    expression = expression.strip()
    if not expression:
        return ""
    if expression.startswith("$$") and expression.endswith("$$"):
        return expression
    return f"$${expression}$$"


def _clean_expression(expression: str) -> str:
    expression = expression.strip()
    expression = expression.replace("\\[", "").replace("\\]", "")
    expression = expression.replace("[", "").replace("]", "")
    expression = expression.strip("` \n\t.")

    boxed_match = re.search(r"\\boxed\{(.+)\}", expression, flags=re.DOTALL)
    if boxed_match:
        expression = boxed_match.group(1).strip()

    if expression.startswith("$") and expression.endswith("$"):
        expression = expression[1:-1].strip()

    return expression


@_gpu
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
        text = (
            "\n".join(f"{message['role']}: {message['content']}" for message in messages)
            + "\nassistant:"
        )

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
        "mode": "local",
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
    return _to_display_math(_extract_final_expression(response)), metrics


def _usage_value(usage, name: str):
    if usage is None:
        return None
    if isinstance(usage, dict):
        return usage.get(name)
    return getattr(usage, name, None)


def _detail_value(details, name: str):
    if details is None:
        return None
    if isinstance(details, dict):
        return details.get(name)
    return getattr(details, name, None)


def _collect_streamed_api_response(client, messages, max_tokens: int, temperature: float):
    stream_kwargs = {
        "max_tokens": max_tokens,
        "stream": True,
        "temperature": temperature,
    }
    try:
        return _read_api_stream(
            client.chat_completion(
                messages,
                **stream_kwargs,
                extra_body={"reasoning_effort": "low"},
            )
        )
    except TypeError:
        return _read_api_stream(client.chat_completion(messages, **stream_kwargs))


def _read_api_stream(stream):
    response_parts = []
    last_chunk = None
    for chunk in stream:
        last_chunk = chunk
        choices = getattr(chunk, "choices", [])
        if not choices:
            continue

        delta = getattr(choices[0], "delta", None)
        token = getattr(delta, "content", "") if delta is not None else ""
        if token:
            response_parts.append(token)

    return "".join(response_parts).strip(), last_chunk


def generate_api_math_representation(
    prompt: str,
    generation_level: str,
    max_new_tokens: int,
    temperature: float,
    hf_token: str,
) -> tuple[str, dict[str, float | int | str | None]]:
    from huggingface_hub import InferenceClient

    started_at = time.perf_counter()
    client = InferenceClient(
        token=hf_token,
        model=REMOTE_MODEL_NAME,
    )
    messages = _build_messages(prompt, generation_level)

    generation_started_at = time.perf_counter()
    api_max_tokens = max(int(max_new_tokens), 1024)
    response, last_chunk = _collect_streamed_api_response(
        client=client,
        messages=messages,
        max_tokens=api_max_tokens,
        temperature=float(temperature),
    )
    finished_at = time.perf_counter()

    usage = getattr(last_chunk, "usage", None) if last_chunk is not None else None
    prompt_tokens = _usage_value(usage, "prompt_tokens")
    completion_tokens = _usage_value(usage, "completion_tokens")
    total_tokens = _usage_value(usage, "total_tokens")
    completion_details = _usage_value(usage, "completion_tokens_details") or {}
    reasoning_tokens = _detail_value(completion_details, "reasoning_tokens")

    if not response:
        raise RuntimeError(
            "API model returned no visible text content. The request appears to "
            "have been spent on hidden reasoning tokens before producing an answer. "
            f"Requested max_tokens: {api_max_tokens}. "
            f"Prompt tokens: {prompt_tokens}. "
            f"Completion tokens: {completion_tokens}. "
            f"Reasoning tokens: {reasoning_tokens}. "
            f"Total tokens: {total_tokens}. "
            f"Last streamed chunk: {last_chunk!r}"
        )

    generation_time = finished_at - generation_started_at
    generated_tokens = completion_tokens or len(response.split())

    metrics = {
        "model": REMOTE_MODEL_NAME,
        "mode": "api",
        "response_time_s": finished_at - started_at,
        "model_ready_time_s": 0.0,
        "generation_time_s": generation_time,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "reasoning_tokens": reasoning_tokens,
        "tokens_per_s": (
            generated_tokens / generation_time
            if generated_tokens is not None and generation_time
            else None
        ),
        "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
        "gpu_peak_allocated_mb": None,
    }
    return _to_display_math(_extract_final_expression(response)), metrics
