import os

from google import genai
from google.genai import types


api_key = os.getenv("GEMINI_API_KEY")
if not api_key:
    raise RuntimeError("GEMINI_API_KEY is required")

client = genai.Client(enterprise=True, api_key=api_key)
response = client.models.generate_content(
    model=os.getenv("GEMINI_MODEL", "gemini-3.5-flash"),
    contents="d/dx x^3",
    config=types.GenerateContentConfig(
        system_instruction=(
            "You are OverSmart Math Solver. Rewrite the user's input as an "
            "equivalent, more sophisticated mathematical expression. "
            "Use basic algebra and high-school mathematics. Return only the final expression in LaTeX $$\\boxed{}$$"
            "display-math format."
        ),
        thinking_config=types.ThinkingConfig(
            thinking_level=types.ThinkingLevel.MEDIUM,
        ),
        max_output_tokens=1024,
    ),
)
print(response.text)
