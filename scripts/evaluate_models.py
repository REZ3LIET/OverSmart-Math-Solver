#!/usr/bin/env python3
"""Evaluate small math LMs for solving and equivalent-expression generation.

Suggested dependencies:
    uv pip install --python .venv/bin/python3.10 \
      torch transformers accelerate sympy psutil datasets

Example:
    .venv/bin/python3.10 scripts/evaluate_models.py \
      --models amd/ReasonLite-0.6B LiquidAI/LFM2-350M-Math \
      --output-dir eval_runs

The default suite is intentionally small. It samples capability areas instead
of running complete public benchmarks, which keeps iteration practical for
small local models.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import gc
import json
import os
import re
import statistics
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError


DEFAULT_MODELS = [
    "Qwen/Qwen2.5-Math-1.5B-Instruct",
    "unsloth/Qwen2.5-Math-1.5B-Instruct-bnb-4bit"
]


@dataclass(frozen=True)
class EvalItem:
    id: str
    category: str
    difficulty: str
    prompt: str
    expected: str
    answer_type: str = "expr"
    notes: str = ""


@dataclass
class EvalResult:
    model: str
    item_id: str
    category: str
    difficulty: str
    prompt: str
    expected: str
    response: str
    extracted_answer: str
    correct: bool
    complexity_ok: bool
    whole_correct: bool
    token_f1: float
    cohesiveness: float
    gibberish_flags: list[str]
    latency_s: float
    prompt_tokens: int
    generated_tokens: int
    tokens_per_s: float
    peak_rss_mb: float
    peak_gpu_mem_mb: float | None
    error: str | None = None
    skipped: bool = False


def built_in_suite() -> list[EvalItem]:
    """Small, targeted suite spanning the requested math capabilities."""
    return [
        EvalItem(
            "arith_001",
            "arithmetic",
            "simple",
            "Compute exactly. Return only the final answer as plain text. Do not use LaTeX or explain: What is 1 + 1?",
            "2",
        ),
        EvalItem(
            "arith_002",
            "arithmetic",
            "simple",
            "Compute exactly. Return only the final answer as plain text. Do not use LaTeX or explain: 17 * 23 - 91",
            "300",
        ),
        EvalItem(
            "trig_001",
            "trigonometry",
            "medium",
            "Compute exactly. Return only the final answer as plain text. Do not use LaTeX or explain: sin(pi/6)^2 + cos(pi/3)",
            "3/4",
        ),
        EvalItem(
            "calc_001",
            "first_order_calculus",
            "medium",
            "Differentiate f(x)=x^3+2*x with respect to x and evaluate at x=2. Return only the final answer as plain text. Do not use LaTeX or explain.",
            "14",
        ),
        EvalItem(
            "calc_002",
            "higher_order_calculus",
            "hard",
            "For f(x)=sin(x)*exp(x), compute the second derivative at x=0. Return only the final answer as plain text. Do not use LaTeX or explain.",
            "2",
        ),
        EvalItem(
            "partial_001",
            "partial_derivatives",
            "hard",
            "Let f(x,y)=x^2*y + sin(x*y). Compute partial^2 f / partial x partial y at (0,1). Return only the final answer as plain text. Do not use LaTeX or explain.",
            "1",
        ),
        EvalItem(
            "series_001",
            "series",
            "hard",
            "Compute the infinite series sum_{n=1}^infty 1/2^n. Return only the final answer as plain text. Do not use LaTeX or explain.",
            "1",
        ),
        EvalItem(
            "taylor_001",
            "taylor_series",
            "hard",
            "Using the Taylor series of e^x, compute the coefficient of x^4. Return only the final answer as plain text. Do not use LaTeX or explain.",
            "1/24",
        ),
        EvalItem(
            "prob_001",
            "probability",
            "medium",
            "A fair die is rolled twice. What is the probability the sum is 7? Return only the final answer as plain text. Do not use LaTeX or explain.",
            "1/6",
        ),
        EvalItem(
            "prob_002",
            "probability",
            "hard",
            "A biased coin has P(H)=0.3. It is flipped 4 times. What is P(exactly 2 heads)? Return only the final answer as plain text. Do not use LaTeX or explain.",
            "0.2646",
        ),
        EvalItem(
            "latex_001",
            "latex_comprehension",
            "medium",
            "Evaluate the LaTeX expression $\\int_0^1 2x\\,dx$. Return only the final answer as plain text. Do not use LaTeX in the answer or explain.",
            "1",
        ),
        EvalItem(
            "latex_002",
            "latex_comprehension",
            "hard",
            "Evaluate the LaTeX expression $\\left.\\frac{\\partial}{\\partial x}(x^2y+e^{xy})\\right|_{(0,0)}$. Return only the final answer as plain text. Do not use LaTeX in the answer or explain.",
            "1",
        ),
        EvalItem(
            "repr1_simple",
            "representation_of_1",
            "simple",
            "Create a simple arithmetic expression equivalent to 1. Return only the expression as plain text. Do not use LaTeX or explain.",
            "1",
            "equivalent_expr",
        ),
        EvalItem(
            "repr1_medium",
            "representation_of_1",
            "medium",
            "Create an expression equivalent to 1 using trigonometry or first-order calculus. Return only the expression as plain text. Do not use LaTeX or explain.",
            "1",
            "equivalent_expr",
        ),
        EvalItem(
            "repr1_hard",
            "representation_of_1",
            "hard",
            "Create an expression equivalent to 1 using a series, higher-order calculus, or partial derivatives. Return only the expression as plain text. Do not use LaTeX or explain.",
            "1",
            "equivalent_expr",
        ),
        EvalItem(
            "repr2_simple",
            "representation_of_2",
            "simple",
            "Create a simple arithmetic expression equivalent to 2, but do not write just 2. Return only the expression as plain text. Do not use LaTeX or explain.",
            "2",
            "equivalent_expr",
        ),
        EvalItem(
            "repr2_medium",
            "representation_of_2",
            "medium",
            "Create an expression equivalent to 2 using trigonometry or first-order calculus. Return only the expression as plain text. Do not use LaTeX or explain.",
            "2",
            "equivalent_expr",
        ),
        EvalItem(
            "repr2_hard",
            "representation_of_2",
            "hard",
            "Create an expression equivalent to 2 using a series, higher-order calculus, or partial derivatives. Return only the expression as plain text. Do not use LaTeX or explain.",
            "2",
            "equivalent_expr",
        ),
    ]


def require_imports() -> dict[str, Any]:
    missing: list[str] = []
    modules: dict[str, Any] = {}
    for name in ["torch", "transformers", "sympy", "psutil"]:
        try:
            modules[name] = __import__(name)
        except ImportError:
            missing.append(name)
    if missing:
        raise SystemExit(
            "Missing required packages: "
            + ", ".join(missing)
            + "\nInstall with: uv pip install --python .venv/bin/python3.10 "
            + "torch transformers accelerate sympy psutil datasets"
        )
    return modules


def load_optional_dataset_samples(limit: int) -> list[EvalItem]:
    """Pull a tiny slice of GSM8K/MATH-style data when datasets is installed."""
    if limit <= 0:
        return []
    try:
        from datasets import load_dataset
    except ImportError:
        return []

    items: list[EvalItem] = []
    try:
        gsm = load_dataset("openai/gsm8k", "main", split=f"test[:{limit}]")
        for idx, row in enumerate(gsm):
            answer = str(row["answer"]).split("####")[-1].strip()
            items.append(
                EvalItem(
                    f"gsm8k_{idx:03d}",
                    "benchmark_gsm8k",
                    "medium",
                    str(row["question"]) + "\nPut only the final answer in \\boxed{}.",
                    answer,
                )
            )
    except Exception as exc:
        message = str(exc).lower()
        if "401" in message or "403" in message or "gated" in message or "token" in message:
            print("Skipping optional GSM8K samples because the dataset requires authentication.", flush=True)
        else:
            print(f"Skipping optional GSM8K samples because loading failed: {exc}", flush=True)
    return items


def unauthenticated_model_access(model_id: str) -> tuple[bool, str | None]:
    """Check model metadata and weight files without using an HF token."""
    api_url = "https://huggingface.co/api/models/" + urllib.parse.quote(model_id, safe="/")
    try:
        with urllib.request.urlopen(api_url, timeout=20) as response:
            metadata = json.load(response)
    except HTTPError as exc:
        if exc.code in {401, 403}:
            return False, f"requires Hugging Face authentication: HTTP {exc.code}"
        if exc.code == 404:
            return False, "model not found or private"
        return False, f"metadata request failed: HTTP {exc.code}"
    except Exception as exc:
        return False, f"metadata request failed: {exc}"

    if metadata.get("private"):
        return False, "private model"
    gated = metadata.get("gated")
    if gated and gated not in {False, "false", "False"}:
        return False, f"gated model: {gated}"

    tree_url = api_url + "/tree/main?recursive=1"
    try:
        with urllib.request.urlopen(tree_url, timeout=20) as response:
            files = json.load(response)
    except HTTPError as exc:
        if exc.code in {401, 403}:
            return False, f"model files require Hugging Face authentication: HTTP {exc.code}"
        return False, f"file tree request failed: HTTP {exc.code}"
    except Exception as exc:
        return False, f"file tree request failed: {exc}"

    has_weights = any((entry.get("path") or "").endswith((".safetensors", ".bin", ".gguf")) for entry in files)
    if not has_weights:
        return False, "no reachable model weight files"
    return True, None


def extract_answer(text: str) -> str:
    boxed = extract_boxed_values(text)
    if boxed:
        return boxed[-1].strip()
    answer_region = re.split(r"</think>", text, flags=re.I)[-1]
    final_patterns = [
        r"(?:final answer|answer)\s*(?:is|:)\s*([^\n]+)",
        r"####\s*([^\n]+)",
    ]
    for pattern in final_patterns:
        found = re.findall(pattern, answer_region, flags=re.I)
        if found:
            return cleanup_answer(found[-1])

    math_candidates = re.findall(
        r"(?:\\d?frac\{[^{}]+\}\{[^{}]+\}|\\d?frac\d+\d+|-?\d+(?:\.\d+)?(?:\s*/\s*-?\d+(?:\.\d+)?)?)",
        answer_region,
    )
    if math_candidates:
        return cleanup_answer(math_candidates[-1])
    lines = [line.strip() for line in answer_region.strip().splitlines() if line.strip()]
    return cleanup_answer(lines[-1] if lines else text.strip())


def extract_boxed_values(text: str) -> list[str]:
    values: list[str] = []
    marker = "\\boxed"
    index = 0
    while True:
        start = text.find(marker, index)
        if start == -1:
            break
        brace = text.find("{", start + len(marker))
        if brace == -1:
            index = start + len(marker)
            continue
        depth = 0
        for pos in range(brace, len(text)):
            char = text[pos]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    values.append(text[brace + 1 : pos])
                    index = pos + 1
                    break
        else:
            index = brace + 1
    return values


def cleanup_answer(answer: str) -> str:
    answer = answer.strip()
    answer = answer.strip("`*$ ")
    answer = re.sub(r"\\\((.*?)\\\)", r"\1", answer)
    answer = re.sub(r"\\\[(.*?)\\\]", r"\1", answer)
    answer = answer.replace("\\,", "")
    answer = answer.rstrip(".")
    return answer


def normalize_math_text(expr: str) -> str:
    expr = cleanup_answer(expr)
    expr = re.sub(r"<think>.*?</think>", "", expr, flags=re.I | re.S)
    expr = expr.replace("\\left", "").replace("\\right", "")
    expr = expr.replace("\\dfrac", "\\frac").replace("\\tfrac", "\\frac")
    expr = re.sub(r"\\frac\s*([0-9])\s*([0-9])", r"(\1)/(\2)", expr)
    expr = re.sub(r"\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}", r"(\1)/(\2)", expr)
    expr = re.sub(r"\\frac\s*\(([^()]*)\)\s*\(([^()]*)\)", r"(\1)/(\2)", expr)
    expr = re.sub(
        r"\\frac\s*\{d\^2\}\s*\{d([A-Za-z])\^2\}\s*([A-Za-z0-9_\\^{}()+*/ -]+)",
        r"diff(\2, \1, 2)",
        expr,
    )
    expr = re.sub(
        r"\\frac\s*\{d\}\s*\{d([A-Za-z])\}\s*([A-Za-z0-9_\\^{}()+*/ -]+)",
        r"diff(\2, \1)",
        expr,
    )
    expr = re.sub(r"\\(sin|cos|tan)\s*\^\s*\{?([0-9]+)\}?\s*\\?([A-Za-z]+)", r"\1(\3)**\2", expr)
    expr = re.sub(r"\\(sin|cos|tan)\s*\\?([A-Za-z]+)", r"\1(\2)", expr)
    replacements = {
        "\\pi": "pi",
        "\\infty": "oo",
        "\\cdot": "*",
        "\\times": "*",
        "\\ln": "log",
        "\\sin": "sin",
        "\\cos": "cos",
        "\\tan": "tan",
        "^": "**",
        "{": "(",
        "}": ")",
    }
    for old, new in replacements.items():
        expr = expr.replace(old, new)
    expr = re.sub(r"e\*\*\(([^()]+)\)", r"exp(\1)", expr)
    expr = re.sub(r"e\*\*([A-Za-z0-9_]+)", r"exp(\1)", expr)
    expr = re.sub(r"(?<=\d),(?=\d)", "", expr)
    return expr.strip()


def sympy_equivalent(candidate: str, expected: str, sympy_module: Any) -> bool:
    sp = sympy_module
    candidate = normalize_math_text(cleanup_answer(candidate))
    expected = normalize_math_text(cleanup_answer(expected))
    locals_map = {
        "sin": sp.sin,
        "cos": sp.cos,
        "tan": sp.tan,
        "exp": sp.exp,
        "log": sp.log,
        "sqrt": sp.sqrt,
        "pi": sp.pi,
        "oo": sp.oo,
        "Sum": sp.Sum,
        "Integral": sp.Integral,
        "diff": sp.diff,
        "theta": sp.Symbol("theta"),
        "x": sp.Symbol("x"),
        "y": sp.Symbol("y"),
    }
    try:
        parse_expr = None
        transformations = None
        try:
            from sympy.parsing.sympy_parser import (
                convert_xor,
                implicit_multiplication_application,
                standard_transformations,
                parse_expr as sympy_parse_expr,
            )

            parse_expr = sympy_parse_expr
            transformations = standard_transformations + (implicit_multiplication_application, convert_xor)
        except Exception:
            pass
        if parse_expr is not None:
            c = parse_expr(candidate, local_dict=locals_map, transformations=transformations)
            e = parse_expr(expected, local_dict=locals_map, transformations=transformations)
        else:
            c = sp.sympify(candidate, locals=locals_map)
            e = sp.sympify(expected, locals=locals_map)
        diff = sp.simplify(c.doit() - e.doit())
        if diff == 0:
            return True
        return bool(abs(float(diff.evalf())) < 1e-6)
    except Exception:
        return cleanup_answer(candidate).lower() == cleanup_answer(expected).lower()


def complexity_match(answer: str, item: EvalItem) -> bool:
    """Check whether an equivalent-expression answer uses the requested complexity."""
    if item.answer_type != "equivalent_expr":
        return True
    text = cleanup_answer(answer).lower()
    hard_markers = [
        "sum",
        "series",
        "lim",
        "limit",
        "integral",
        "diff",
        "derivative",
        "partial",
        "d^2",
        "second",
        "taylor",
        "fourier",
        "oo",
        "infty",
        "\\infty",
        "\\sum",
        "\\int",
        "\\partial",
        "factorial",
    ]
    medium_markers = [
        "sin",
        "cos",
        "tan",
        "trig",
        "derivative",
        "diff",
        "integral",
        "\\sin",
        "\\cos",
        "\\tan",
        "\\int",
    ]
    has_hard = any(marker in text for marker in hard_markers)
    has_medium = any(marker in text for marker in medium_markers)
    if item.difficulty == "simple":
        return not has_medium and not has_hard
    if item.difficulty == "medium":
        return has_medium and not has_hard
    if item.difficulty == "hard":
        return has_hard
    return True


def token_f1(prediction: str, reference: str) -> float:
    pred_tokens = re.findall(r"\w+|[^\w\s]", prediction.lower())
    ref_tokens = re.findall(r"\w+|[^\w\s]", reference.lower())
    if not pred_tokens and not ref_tokens:
        return 1.0
    if not pred_tokens or not ref_tokens:
        return 0.0
    pred_counts = Counter(pred_tokens)
    ref_counts = Counter(ref_tokens)
    overlap = sum((pred_counts & ref_counts).values())
    if overlap == 0:
        return 0.0
    precision = overlap / len(pred_tokens)
    recall = overlap / len(ref_tokens)
    return 2 * precision * recall / (precision + recall)


def gibberish_metrics(text: str) -> tuple[float, list[str]]:
    flags: list[str] = []
    stripped = text.strip()
    if not stripped:
        return 0.0, ["empty"]
    chars = len(stripped)
    alpha = sum(ch.isalpha() for ch in stripped)
    printable = sum(ch.isprintable() for ch in stripped)
    weird_ratio = 1.0 - printable / max(chars, 1)
    repeated = re.search(r"(.{8,}?)\1{2,}", stripped, flags=re.S) is not None
    avg_word_len = statistics.mean([len(w) for w in re.findall(r"[A-Za-z]+", stripped)] or [0])
    boxed_count = stripped.count("\\boxed")
    if weird_ratio > 0.05:
        flags.append("non_printable")
    if repeated:
        flags.append("repetition")
    if avg_word_len > 18:
        flags.append("long_word_runs")
    if alpha / max(chars, 1) < 0.05 and len(stripped) > 40:
        flags.append("low_language_content")
    if boxed_count > 4:
        flags.append("excess_boxed_answers")
    score = 1.0
    score -= min(0.35, weird_ratio * 3)
    score -= 0.25 if repeated else 0.0
    score -= 0.15 if avg_word_len > 18 else 0.0
    score -= 0.10 if boxed_count > 4 else 0.0
    return max(0.0, score), flags


def get_rss_mb(psutil_module: Any) -> float:
    return float(psutil_module.Process(os.getpid()).memory_info().rss / (1024 * 1024))


def get_gpu_peak_mb(torch_module: Any) -> float | None:
    if not torch_module.cuda.is_available():
        return None
    return float(torch_module.cuda.max_memory_allocated() / (1024 * 1024))


def build_prompt(tokenizer: Any, item: EvalItem) -> Any:
    messages = [{"role": "user", "content": item.prompt}]
    try:
        return tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            tokenize=False,
        )
    except Exception:
        return item.prompt


def decode_generated_text(tokenizer: Any, outputs: Any, prompt_token_count: int) -> tuple[str, int]:
    generated_ids = outputs[0][prompt_token_count:]
    text = tokenizer.decode(
        generated_ids,
        skip_special_tokens=True,
        clean_up_tokenization_spaces=True,
    )
    return text, int(generated_ids.shape[-1])


def generate_one(
    model: Any,
    tokenizer: Any,
    item: EvalItem,
    args: argparse.Namespace,
    modules: dict[str, Any],
) -> EvalResult:
    torch = modules["torch"]
    psutil = modules["psutil"]
    sympy = modules["sympy"]
    prompt = build_prompt(tokenizer, item)
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    prompt_tokens = int(inputs["input_ids"].shape[-1])
    start_rss = get_rss_mb(psutil)
    if torch.cuda.is_available():
        torch.cuda.reset_peak_memory_stats()
        torch.cuda.synchronize()
    start = time.perf_counter()
    generate_kwargs: dict[str, Any] = {
        "max_new_tokens": args.max_new_tokens,
        "do_sample": args.temperature > 0,
        "pad_token_id": tokenizer.eos_token_id,
    }
    if args.temperature > 0:
        generate_kwargs["temperature"] = args.temperature
        generate_kwargs["top_p"] = args.top_p
    with torch.no_grad():
        outputs = model.generate(**inputs, **generate_kwargs)
    if torch.cuda.is_available():
        torch.cuda.synchronize()
    latency = time.perf_counter() - start
    response, generated_tokens = decode_generated_text(tokenizer, outputs, inputs["input_ids"].shape[-1])
    extracted = extract_answer(response)
    correct = sympy_equivalent(extracted, item.expected, sympy)
    complexity_ok = complexity_match(extracted, item)
    whole_correct = correct and complexity_ok
    f1 = token_f1(extracted, item.expected)
    cohesive, flags = gibberish_metrics(response)
    peak_rss = max(get_rss_mb(psutil), start_rss)
    peak_gpu = get_gpu_peak_mb(torch)
    return EvalResult(
        model=args.current_model,
        item_id=item.id,
        category=item.category,
        difficulty=item.difficulty,
        prompt=item.prompt,
        expected=item.expected,
        response=response,
        extracted_answer=extracted,
        correct=correct,
        complexity_ok=complexity_ok,
        whole_correct=whole_correct,
        token_f1=f1,
        cohesiveness=cohesive,
        gibberish_flags=flags,
        latency_s=latency,
        prompt_tokens=prompt_tokens,
        generated_tokens=generated_tokens,
        tokens_per_s=generated_tokens / latency if latency > 0 else 0.0,
        peak_rss_mb=peak_rss,
        peak_gpu_mem_mb=peak_gpu,
    )


def load_model(model_id: str, args: argparse.Namespace, modules: dict[str, Any]) -> tuple[Any, Any]:
    torch = modules["torch"]
    transformers = modules["transformers"]
    tokenizer = transformers.AutoTokenizer.from_pretrained(model_id, trust_remote_code=args.trust_remote_code)
    if tokenizer.pad_token_id is None and tokenizer.eos_token_id is not None:
        tokenizer.pad_token = tokenizer.eos_token

    kwargs: dict[str, Any] = {
        "device_map": args.device_map,
        "trust_remote_code": args.trust_remote_code,
    }
    if args.load_in_4bit:
        kwargs["load_in_4bit"] = True
    elif args.load_in_8bit:
        kwargs["load_in_8bit"] = True
    else:
        dtype = getattr(torch, args.dtype) if args.dtype != "auto" else "auto"
        kwargs["dtype"] = dtype
    model = transformers.AutoModelForCausalLM.from_pretrained(model_id, **kwargs)
    model.eval()
    return model, tokenizer


def summarize(results: list[EvalResult]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    grouped: dict[tuple[str, str], list[EvalResult]] = defaultdict(list)
    for result in results:
        grouped[(result.model, "ALL")].append(result)
        grouped[(result.model, result.category)].append(result)
    for (model, category), group in sorted(grouped.items()):
        evaluated = [r for r in group if not r.skipped]
        n = len(evaluated)
        correct = sum(r.correct for r in evaluated)
        whole_correct = sum(r.whole_correct for r in evaluated)
        complexity_checks = [r.complexity_ok for r in evaluated if r.category.startswith("representation_of_")]
        rows.append(
            {
                "model": model,
                "category": category,
                "n": n,
                "skipped": len(group) - n,
                "accuracy": correct / n if n else 0.0,
                "whole_accuracy": whole_correct / n if n else 0.0,
                "complexity_accuracy": (
                    sum(complexity_checks) / len(complexity_checks) if complexity_checks else None
                ),
                "token_f1": statistics.mean(r.token_f1 for r in evaluated) if evaluated else 0.0,
                "cohesiveness": statistics.mean(r.cohesiveness for r in evaluated) if evaluated else 0.0,
                "latency_s": statistics.mean(r.latency_s for r in evaluated) if evaluated else 0.0,
                "tokens_per_s": statistics.mean(r.tokens_per_s for r in evaluated) if evaluated else 0.0,
                "peak_rss_mb": max(r.peak_rss_mb for r in evaluated) if evaluated else 0.0,
                "peak_gpu_mem_mb": max_optional(r.peak_gpu_mem_mb for r in evaluated),
            }
        )
    return rows


def max_optional(values: Iterable[float | None]) -> float | None:
    present = [v for v in values if v is not None]
    return max(present) if present else None


def timestamp_slug() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d_%H%M%S_UTC")


def resolve_output_dir(args: argparse.Namespace) -> Path:
    base_dir = Path(args.output_dir)
    if args.no_timestamp:
        return base_dir
    run_name = args.run_name.strip() if args.run_name else timestamp_slug()
    run_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", run_name).strip("_") or timestamp_slug()
    return base_dir / run_name


def write_outputs(
    results: list[EvalResult],
    summary: list[dict[str, Any]],
    output_dir: Path,
    args: argparse.Namespace,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = output_dir / "results.jsonl"
    with jsonl_path.open("w", encoding="utf-8") as handle:
        for result in results:
            handle.write(json.dumps(asdict(result), ensure_ascii=False) + "\n")

    metadata_path = output_dir / "run_metadata.json"
    metadata = {
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "models": args.models,
        "output_dir": str(output_dir),
        "max_new_tokens": args.max_new_tokens,
        "temperature": args.temperature,
        "top_p": args.top_p,
        "dtype": args.dtype,
        "device_map": args.device_map,
        "load_in_4bit": args.load_in_4bit,
        "load_in_8bit": args.load_in_8bit,
        "trust_remote_code": args.trust_remote_code,
        "gsm8k_samples": args.gsm8k_samples,
        "limit_items": args.limit_items,
        "allow_auth_required": args.allow_auth_required,
    }
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    summary_path = output_dir / "summary.csv"
    fieldnames = [
        "model",
        "category",
        "n",
        "skipped",
        "accuracy",
        "whole_accuracy",
        "complexity_accuracy",
        "token_f1",
        "cohesiveness",
        "latency_s",
        "tokens_per_s",
        "peak_rss_mb",
        "peak_gpu_mem_mb",
    ]
    with summary_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(summary)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS, help="HF model IDs to evaluate.")
    parser.add_argument("--output-dir", default="eval_runs", help="Base directory for timestamped eval runs.")
    parser.add_argument("--run-name", default="", help="Optional timestamp directory name override.")
    parser.add_argument("--no-timestamp", action="store_true", help="Write directly to --output-dir.")
    parser.add_argument("--max-new-tokens", type=int, default=512)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--dtype", default="bfloat16", choices=["auto", "float16", "bfloat16", "float32"])
    parser.add_argument("--device-map", default="auto")
    parser.add_argument("--load-in-4bit", action="store_true", help="Use bitsandbytes 4-bit loading.")
    parser.add_argument("--load-in-8bit", action="store_true", help="Use bitsandbytes 8-bit loading.")
    parser.add_argument("--trust-remote-code", action="store_true")
    parser.add_argument("--gsm8k-samples", type=int, default=0, help="Optionally append a small GSM8K test slice.")
    parser.add_argument("--limit-items", type=int, default=0, help="Debug option: only run first N eval items.")
    parser.add_argument(
        "--allow-auth-required",
        action="store_true",
        help="Try loading gated/private models instead of skipping them during unauthenticated preflight.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    modules = require_imports()
    suite = built_in_suite() + load_optional_dataset_samples(args.gsm8k_samples)
    if args.limit_items > 0:
        suite = suite[: args.limit_items]

    all_results: list[EvalResult] = []
    for model_id in args.models:
        args.current_model = model_id
        print(f"\n=== Evaluating {model_id} on {len(suite)} items ===", flush=True)
        if not args.allow_auth_required:
            accessible, reason = unauthenticated_model_access(model_id)
            if not accessible:
                print(f"Skipping {model_id}: {reason}", flush=True)
                for item in suite:
                    all_results.append(
                        EvalResult(
                            model=model_id,
                            item_id=item.id,
                            category=item.category,
                            difficulty=item.difficulty,
                            prompt=item.prompt,
                            expected=item.expected,
                            response="",
                            extracted_answer="",
                            correct=False,
                            complexity_ok=False,
                            whole_correct=False,
                            token_f1=0.0,
                            cohesiveness=0.0,
                            gibberish_flags=["skipped_auth_or_access"],
                            latency_s=0.0,
                            prompt_tokens=0,
                            generated_tokens=0,
                            tokens_per_s=0.0,
                            peak_rss_mb=0.0,
                            peak_gpu_mem_mb=None,
                            error=reason,
                            skipped=True,
                        )
                    )
                continue
        try:
            model, tokenizer = load_model(model_id, args, modules)
        except Exception as exc:
            print(f"Failed to load {model_id}: {exc}", flush=True)
            for item in suite:
                all_results.append(
                    EvalResult(
                        model=model_id,
                        item_id=item.id,
                        category=item.category,
                        difficulty=item.difficulty,
                        prompt=item.prompt,
                        expected=item.expected,
                        response="",
                        extracted_answer="",
                        correct=False,
                        complexity_ok=False,
                        whole_correct=False,
                        token_f1=0.0,
                        cohesiveness=0.0,
                        gibberish_flags=["load_error"],
                        latency_s=0.0,
                        prompt_tokens=0,
                        generated_tokens=0,
                        tokens_per_s=0.0,
                        peak_rss_mb=0.0,
                        peak_gpu_mem_mb=None,
                        error=str(exc),
                    )
                )
            continue

        for idx, item in enumerate(suite, start=1):
            print(f"[{idx:02d}/{len(suite)}] {item.id}", flush=True)
            try:
                result = generate_one(model, tokenizer, item, args, modules)
            except Exception as exc:
                result = EvalResult(
                    model=model_id,
                    item_id=item.id,
                    category=item.category,
                    difficulty=item.difficulty,
                    prompt=item.prompt,
                    expected=item.expected,
                    response="",
                    extracted_answer="",
                    correct=False,
                    complexity_ok=False,
                    whole_correct=False,
                    token_f1=0.0,
                    cohesiveness=0.0,
                    gibberish_flags=["generation_error"],
                    latency_s=0.0,
                    prompt_tokens=0,
                    generated_tokens=0,
                    tokens_per_s=0.0,
                    peak_rss_mb=0.0,
                    peak_gpu_mem_mb=None,
                    error=str(exc),
                )
            all_results.append(result)

        del model
        del tokenizer
        gc.collect()
        if modules["torch"].cuda.is_available():
            modules["torch"].cuda.empty_cache()

    summary = summarize(all_results)
    output_dir = resolve_output_dir(args)
    write_outputs(all_results, summary, output_dir, args)
    print(f"\nWrote {output_dir / 'results.jsonl'}")
    print(f"Wrote {output_dir / 'summary.csv'}")
    print(f"Wrote {output_dir / 'run_metadata.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
