import os
import traceback

import gradio as gr

from model_inference import generate_math_representation


def format_inference_report(metrics):
    if not metrics:
        return ""

    gpu_memory = metrics["gpu_peak_allocated_mb"]
    gpu_line = (
        f"GPU peak allocated: {gpu_memory:.1f} MB"
        if gpu_memory is not None
        else "GPU peak allocated: unavailable"
    )

    return "\n".join(
        [
            "Inference Report",
            f"Model: {metrics['model']}",
            f"Response time: {metrics['response_time_s']:.2f} s",
            f"Model ready overhead: {metrics['model_ready_time_s']:.2f} s",
            f"Generation time: {metrics['generation_time_s']:.2f} s",
            f"Prompt tokens: {metrics['prompt_tokens']}",
            f"Generated tokens: {metrics['generated_tokens']}",
            f"Throughput: {metrics['tokens_per_s']:.2f} tokens/s",
            f"Peak process memory: {metrics['peak_rss_mb']:.1f} MB",
            gpu_line,
        ]
    )


def generate_response(
    prompt,
    generation_level,
    use_local_model,
    max_new_tokens,
    temperature
):
    prompt = prompt or ""
    if not prompt.strip():
        return "", ""

    if not use_local_model:
        return "Enable 'Use Local Model' to generate with the Hugging Face model.", ""

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
        return "", f"Inference failed: {type(exc).__name__}: {exc}\n\n{trace}"

    return response, format_inference_report(metrics)


# ---------------------------------------------------------
# Example prompts
# ---------------------------------------------------------
EXAMPLE_PROMPTS = [
    "1 + 1",
    "x^2 + 2x + 1",
    "sin(x)^2 + cos(x)^2",
    "d/dx x^3",
    "integral from 0 to 1 of 2x dx",
    "partial derivative of x^2*y + sin(x*y) with respect to x",
]


# ---------------------------------------------------------
# UI
# ---------------------------------------------------------
with gr.Blocks(title="SLM Playground") as demo:

    gr.Markdown(
        """
        # SLM Playground
        Test and experiment with your language model.
        """
    )

    # Input / Output side-by-side
    with gr.Row():

        with gr.Column():
            input_text = gr.Textbox(
                label="Input",
                placeholder="Enter your prompt...",
                lines=10,
            )

        with gr.Column():
            output_text = gr.Markdown(
                label="Output",
            )

    inference_report = gr.Textbox(
        label="Inference Report",
        placeholder="Performance metrics will appear after generation.",
        lines=10,
        interactive=False,
    )

    generate_button = gr.Button(
        "Generate",
        variant="primary",
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

    # -----------------------------------------------------
    # Configuration
    # -----------------------------------------------------
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
            value=128,
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
            label="Use Local Model",
            value=True,
        )

    # -----------------------------------------------------
    # Events
    # -----------------------------------------------------
    generate_button.click(
        fn=generate_response,
        inputs=[
            input_text,
            generation_level,
            use_local_model,
            max_new_tokens,
            temperature
        ],
        outputs=[
            output_text,
            inference_report,
        ],
    )

    # Allow Enter/Ctrl+Enter style submission through the
    # textbox's submit event as well.
    input_text.submit(
        fn=generate_response,
        inputs=[
            input_text,
            generation_level,
            use_local_model,
            max_new_tokens,
            temperature
        ],
        outputs=[
            output_text,
            inference_report,
        ],
    )


# ---------------------------------------------------------
# Launch locally
# ---------------------------------------------------------
if __name__ == "__main__":
    demo.queue(max_size=8).launch(
        server_name="0.0.0.0",
        server_port=int(os.getenv("PORT", "7860")),
    )
