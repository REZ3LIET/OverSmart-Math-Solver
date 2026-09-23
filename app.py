import os
import traceback

import gradio as gr

from model_inference import generate_api_math_representation, generate_math_representation


# Hugging Face Spaces configures OAuth for us. A standalone deployment does
# not, so enabling LoginButton there would make Gradio abort during startup.
HF_OAUTH_ENABLED = bool(os.getenv("SPACE_ID")) or os.getenv(
    "ENABLE_HF_OAUTH", ""
).lower() in {"1", "true", "yes"}
SERVER_HF_TOKEN = os.getenv("HF_TOKEN")


def format_inference_report(metrics):
    if not metrics:
        return ""

    def format_metric(value, suffix=""):
        if value is None:
            return "unavailable"
        if isinstance(value, float):
            return f"{value:.2f}{suffix}"
        return f"{value}{suffix}"

    gpu_memory = metrics["gpu_peak_allocated_mb"]
    gpu_line = (
        f"GPU peak allocated: {gpu_memory:.1f} MB"
        if gpu_memory is not None
        else "GPU peak allocated: unavailable"
    )

    return "\n".join(
        [
            "### Inference Report",
            f"- **Model:** `{metrics['model']}`",
            f"- **Mode:** {metrics['mode']}",
            f"- **Response time:** {format_metric(metrics['response_time_s'], ' s')}",
            f"- **Model ready overhead:** {format_metric(metrics['model_ready_time_s'], ' s')}",
            f"- **Generation time:** {format_metric(metrics['generation_time_s'], ' s')}",
            f"- **Prompt tokens:** {format_metric(metrics['prompt_tokens'])}",
            f"- **Generated tokens:** {format_metric(metrics['generated_tokens'])}",
            f"- **Reasoning tokens:** {format_metric(metrics.get('reasoning_tokens'))}",
            f"- **Throughput:** {format_metric(metrics['tokens_per_s'], ' tokens/s')}",
            f"- **Peak process memory:** {format_metric(metrics['peak_rss_mb'], ' MB')}",
            f"- **{gpu_line}**",
        ]
    )


def generate_response(
    prompt,
    generation_level,
    use_local_model,
    max_new_tokens,
    temperature,
    hf_access_token="",
    hf_token: gr.OAuthToken = None,
):
    prompt = prompt or ""
    if not prompt.strip():
        return "", ""

    if not use_local_model:
        token = (
            getattr(hf_token, "token", None)
            or (hf_access_token or "").strip()
            or SERVER_HF_TOKEN
        )
        if not token:
            # Standalone deployments do not have Hugging Face OAuth. Fall back
            # locally instead of preventing the user from running the app.
            return generate_response(
                prompt,
                generation_level,
                True,
                max_new_tokens,
                temperature,
                hf_access_token,
                hf_token,
            )

        try:
            response, metrics = generate_api_math_representation(
                prompt=prompt,
                generation_level=generation_level,
                max_new_tokens=max_new_tokens,
                temperature=temperature,
                hf_token=token,
            )
        except Exception as remote_exc:
            remote_trace = traceback.format_exc()
            print("Remote inference failed; trying the local model.", flush=True)
            print(remote_trace, flush=True)

            try:
                response, metrics = generate_math_representation(
                    prompt=prompt,
                    generation_level=generation_level,
                    max_new_tokens=max_new_tokens,
                    temperature=temperature,
                )
            except Exception as local_exc:
                local_trace = traceback.format_exc()
                print("Local fallback inference failed.", flush=True)
                print(local_trace, flush=True)
                return "", (
                    "### Inference Failed\n\n"
                    "Both the remote model and the local fallback failed.\n\n"
                    f"- **Remote:** {type(remote_exc).__name__}: {remote_exc}\n"
                    f"- **Local:** {type(local_exc).__name__}: {local_exc}"
                )

            print(f"generated local fallback response: {response}")
            fallback_notice = (
                "### Local Fallback Used\n\n"
                f"The remote model failed with `{type(remote_exc).__name__}`, "
                "so the request was completed by the local model.\n\n"
            )
            return response, fallback_notice + format_inference_report(metrics)

        print(f"generated response: {response}")
        return response, format_inference_report(metrics)

    try:
        response, metrics = generate_math_representation(
            prompt=prompt,
            generation_level=generation_level,
            max_new_tokens=max_new_tokens,
            temperature=temperature,
        )
    except Exception as exc:
        trace = traceback.format_exc()
        print(trace, flush=True)
        return "", (
            f"### Inference Failed\n\n"
            f"**{type(exc).__name__}:** {exc}\n\n"
            f"```text\n{trace}\n```"
        )

    print(f"generated response: {response}")
    return response, format_inference_report(metrics)


EXAMPLE_PROMPTS = [
    "1 + 1",
    "x^2 + 2x + 1",
    "sin(x)^2 + cos(x)^2",
    "d/dx x^3",
    "integral from 0 to 1 of 2x dx",
    "partial derivative of x^2*y + sin(x*y) with respect to x",
]

with gr.Blocks(title="OSMS") as demo:
    if HF_OAUTH_ENABLED:
        gr.LoginButton()

    hf_access_token = gr.Textbox(
        label="Hugging Face access token",
        placeholder="hf_...",
        type="password",
        visible=not HF_OAUTH_ENABLED,
    )

    gr.Markdown(
        """
        # OverSmart Math Solver
        For problems which require human brains.
        """
    )

    input_text = gr.Textbox(
        label="Input",
        placeholder="Enter your prompt...",
        lines=10,
    )

    output_text = gr.Markdown(
        label="Output",
        value="Generated Answer",
    )

    generate_button = gr.Button(
        "Solve",
        variant="primary",
    )

    inference_report = gr.Markdown(
        label="Inference Report",
        value="Performance metrics will appear after generation.",
    )

    # -----------------------------------------------------
    # Example prompts
    # -----------------------------------------------------
    gr.Markdown("### Example Prompts")

    gr.Examples(
        examples=[[prompt] for prompt in EXAMPLE_PROMPTS],
        inputs=input_text,
        label=None,
    )

    with gr.Accordion("Configuration", open=False):
        generation_level = gr.Radio(
            choices=[
                "Highschool",
                "Undergraduate",
                "Masters",
                "PhD",
            ],
            value="Highschool",
            label="Output Level",
        )

        max_new_tokens = gr.Slider(
            minimum=32,
            maximum=2048,
            value=512,
            step=32,
            label="Max New Tokens",
        )

        temperature = gr.Slider(
            minimum=0.0,
            maximum=2.0,
            value=0.7,
            step=0.05,
            label="Temperature",
        )

        use_local_model = gr.Checkbox(
            label="Use local ZeroGPU model",
            value=not HF_OAUTH_ENABLED and not bool(SERVER_HF_TOKEN),
        )

    generation_inputs = [
        input_text,
        generation_level,
        use_local_model,
        max_new_tokens,
        temperature,
        hf_access_token,
    ]
    generation_outputs = [
        output_text,
        inference_report,
    ]

    generate_button.click(
        fn=generate_response,
        inputs=generation_inputs,
        outputs=generation_outputs,
    )

    input_text.submit(
        fn=generate_response,
        inputs=generation_inputs,
        outputs=generation_outputs,
    )


if __name__ == "__main__":
    demo.launch(
        server_name=os.getenv("GRADIO_SERVER_NAME", "127.0.0.1"),
        server_port=int(os.getenv("GRADIO_SERVER_PORT", "8015")),
        ssr_mode=False,
    )
