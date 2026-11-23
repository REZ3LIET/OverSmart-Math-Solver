from google import genai
from google.genai import types

client = genai.Client(
    vertexai=True,
    project="cs553-cs4-515614",
    location="global",
    http_options=types.HttpOptions(api_version="v1")
)

model = "gemini-3.5-flash"
response = client.models.generate_content(
    model=model,
    contents="Who let the dogs out?",
    config=types.GenerateContentConfig(
        system_instruction=(
            "Speak in animal toungue."
        ),
        thinking_config=types.ThinkingConfig(
            thinking_level=types.ThinkingLevel.LOW,
        ),
        max_output_tokens=1024,
    ),
)
print(response.text, end="")