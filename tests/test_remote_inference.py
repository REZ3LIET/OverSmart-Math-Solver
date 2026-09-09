import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

# Allow imports from the project root when this file is run from tests/
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from model_inference import generate_api_math_representation


def make_chunk(content):
    return SimpleNamespace(
        choices=[
            SimpleNamespace(
                delta=SimpleNamespace(content=content)
            )
        ]
    )


class FakeStreamingClient:
    def __init__(self, token, model):
        self.token = token
        self.model = model

    def chat_completion(self, *args, **kwargs):
        yield make_chunk("Expression: ")
        yield make_chunk("$$10 \\\\times 10$$")


class FakeBlankClient:
    def __init__(self, token, model):
        self.token = token
        self.model = model

    def chat_completion(self, *args, **kwargs):
        yield make_chunk("")
        yield make_chunk(None)


def test_streaming_response_is_returned():
    with patch("huggingface_hub.InferenceClient", FakeStreamingClient):
        response, metrics = generate_api_math_representation(
            prompt="90 + 10",
            generation_level="Highschool",
            max_new_tokens=64,
            temperature=0.7,
            hf_token="fake-token",
        )

    assert response == "$$10 \\\\times 10$$"
    assert metrics["mode"] == "api"
    assert metrics["generated_tokens"] > 0


def test_blank_stream_raises_clear_error():
    with patch("huggingface_hub.InferenceClient", FakeBlankClient):
        try:
            generate_api_math_representation(
                prompt="1 + 1",
                generation_level="Highschool",
                max_new_tokens=64,
                temperature=0.7,
                hf_token="fake-token",
            )
        except RuntimeError as error:
            assert "returned no visible text content" in str(error)
        else:
            raise AssertionError("Expected RuntimeError")
