import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

# Allow imports from the project root when this file is run from tests/.
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


class RemoteInferenceTest(unittest.TestCase):
    def test_streaming_response_is_returned(self):
        fake_module = SimpleNamespace(InferenceClient=FakeStreamingClient)
        with patch.dict(sys.modules, {"huggingface_hub": fake_module}):
            response, metrics = generate_api_math_representation(
                prompt="90 + 10",
                generation_level="Highschool",
                max_new_tokens=64,
                temperature=0.7,
                hf_token="fake-token",
            )

        self.assertEqual(response, "$$10 \\\\times 10$$")
        self.assertEqual(metrics["mode"], "api")
        self.assertGreater(metrics["generated_tokens"], 0)

    def test_blank_stream_raises_clear_error(self):
        fake_module = SimpleNamespace(InferenceClient=FakeBlankClient)
        with patch.dict(sys.modules, {"huggingface_hub": fake_module}):
            with self.assertRaisesRegex(
                RuntimeError,
                "returned no visible text content",
            ):
                generate_api_math_representation(
                    prompt="1 + 1",
                    generation_level="Highschool",
                    max_new_tokens=64,
                    temperature=0.7,
                    hf_token="fake-token",
                )


if __name__ == "__main__":
    unittest.main()
