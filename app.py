import os

import gradio as gr
from google import genai
from google.genai import types


GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.5-flash")

if not GEMINI_API_KEY:
    raise RuntimeError("GEMINI_API_KEY is required")

client = genai.Client(enterprise=True, api_key=GEMINI_API_KEY)

LEVEL_INSTRUCTIONS = {
    "Highschool": "Use basic algebra and high-school mathematics.",
    "Undergraduate": "Use undergraduate calculus, trigonometry, or linear algebra.",
    "Masters": "Use advanced calculus or partial differential equations.",
    "PhD": "Use advanced mathematical machinery when appropriate.",
}


def generate_response(prompt, generation_level, max_output_tokens):
    prompt = (prompt or "").strip()
    if not prompt:
        return ""

    level_instruction = LEVEL_INSTRUCTIONS.get(
        generation_level,
        LEVEL_INSTRUCTIONS["Highschool"],
    )
    try:
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                system_instruction=(
                    "You are OverSmart Math Solver. Rewrite the user's input as an "
                    "equivalent, more sophisticated mathematical expression. "
                    f"{level_instruction} Return only the final expression in LaTeX "
                    "display-math format."
                ),
                thinking_config=types.ThinkingConfig(
                    thinking_level=types.ThinkingLevel.LOW,
                ),
                max_output_tokens=int(max_output_tokens),
            ),
        )
    except Exception as error:
        message = str(error).splitlines()[0] if str(error) else type(error).__name__
        return f"### Gemini API Error\n\n{message}"

    return response.text or "The model returned no text."


EXAMPLE_PROMPTS = [
    "1 + 1",
    "x^2 + 2x + 1",
    "sin(x)^2 + cos(x)^2",
    "d/dx x^3",
    "integral from 0 to 1 of 2x dx",
]

with gr.Blocks(title="OSMS") as demo:
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

    with gr.Accordion("Configuration", open=False):
        generation_level = gr.Radio(
            choices=list(LEVEL_INSTRUCTIONS),
            value="Highschool",
            label="Output Level",
        )
        max_output_tokens = gr.Slider(
            minimum=32,
            maximum=1024,
            value=256,
            step=32,
            label="Maximum Output Tokens",
        )

    generate_button = gr.Button("Solve", variant="primary")
    output_text = gr.Markdown(label="Output", value="Generated Answer")

    gr.Examples(
        examples=[[prompt] for prompt in EXAMPLE_PROMPTS],
        inputs=input_text,
        label="Example Prompts",
    )

    generation_inputs = [input_text, generation_level, max_output_tokens]
    generate_button.click(
        fn=generate_response,
        inputs=generation_inputs,
        outputs=output_text,
    )
    input_text.submit(
        fn=generate_response,
        inputs=generation_inputs,
        outputs=output_text,
    )


if __name__ == "__main__":
    demo.launch(
        server_name=os.getenv("GRADIO_SERVER_NAME", "0.0.0.0"),
        server_port=int(os.getenv("GRADIO_SERVER_PORT", "7860")),
        ssr_mode=False,
    )
