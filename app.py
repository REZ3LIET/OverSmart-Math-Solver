import os
import re

import gradio as gr
from google import genai
from google.genai import types


GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = "gemini-3.8-flash"

if not GEMINI_API_KEY:
    raise RuntimeError("GEMINI_API_KEY is required")

client = genai.Client(enterprise=True, api_key=GEMINI_API_KEY)

LEVEL_INSTRUCTIONS = {
    "Highschool": "Use basic algebra and high-school mathematics.",
    "Undergraduate": "Use undergraduate calculus, trigonometry, or linear algebra.",
    "Masters": "Use advanced calculus or partial differential equations.",
    "PhD": "Use advanced mathematical machinery when appropriate.",
}


def format_latex(text):
    expression = text.strip()
    lines = expression.splitlines()
    if lines and lines[0].strip().startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    expression = "\n".join(lines).strip()

    for pattern in (r"\$\$(.*?)\$\$", r"\\\[(.*?)\\\]", r"\\\((.*?)\\\)"):
        matches = re.findall(pattern, expression, flags=re.DOTALL)
        if matches:
            expression = matches[-1].strip()
            break

    boxed_prefix = r"\boxed{"
    if expression.startswith(boxed_prefix):
        boxed_expression = expression[len(boxed_prefix) :]
        depth = 1
        for index, character in enumerate(boxed_expression):
            if character == "{" and (index == 0 or boxed_expression[index - 1] != "\\"):
                depth += 1
            elif character == "}" and (
                index == 0 or boxed_expression[index - 1] != "\\"
            ):
                depth -= 1
                if depth == 0:
                    boxed_expression = boxed_expression[:index]
                    break
        expression = boxed_expression

    expression = rf"\boxed{{{expression}}}"

    return f"$$\n{expression}\n$$"


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
                    f"{level_instruction} Return only the final expression without reasoning in LaTeX "
                    "as: $$\\boxed{...}$$. \nDo not include prose, code fences, or "
                    "multiple alternatives."
                ),
                thinking_config=types.ThinkingConfig(
                    thinking_level=types.ThinkingLevel.MEDIUM,
                ),
                max_output_tokens=int(max_output_tokens),
            ),
        )
    except Exception as error:
        message = str(error).splitlines()[0] if str(error) else type(error).__name__
        return f"### Gemini API Error\n\n{message}"

    if not response.text:
        return "The model returned no text."
    print(response.text)
    return format_latex(response.text)


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
            minimum=1024,
            maximum=1024*2,
            value=1024,
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
