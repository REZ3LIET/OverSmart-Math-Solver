import os

from google import genai
from google.genai import types


api_key = os.getenv("GEMINI_API_KEY")
if not api_key:
    raise RuntimeError("GEMINI_API_KEY is required")

client = genai.Client(enterprise=True, api_key=api_key)
response = client.models.generate_content(
    model=os.getenv("GEMINI_MODEL", "gemini-3.5-flash"),
    contents="Who let the dogs out?",
    config=types.GenerateContentConfig(
        system_instruction="Speak in animal tongue.",
        thinking_config=types.ThinkingConfig(
            thinking_level=types.ThinkingLevel.LOW,
        ),
        max_output_tokens=1024,
    ),
)
print(response.text, end="")
