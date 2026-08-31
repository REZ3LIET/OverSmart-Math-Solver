import os
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from model_inference import generate_api_math_representation


def make_chunk(content=None):
    return SimpleNamespace(
        choices=[
            SimpleNamespace(
                delta=SimpleNamespace(content=content),
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


class RemoteInferenceTests(unittest.TestCase):
    def test_streaming_response_is_returned(self):
        with patch("huggingface_hub.InferenceClient", FakeStreamingClient):
            response, metrics = generate_api_math_representation(
                prompt="90 + 10",
                generation_level="Highschool",
                max_new_tokens=64,
                temperature=0.7,
                hf_token="fake-token",
            )

        self.assertEqual(response, "$$10 \\\\times 10$$")
        self.assertEqual(metrics["mode"], "api")
        self.assertGreater(metrics["response_time_s"], 0)
        self.assertGreater(metrics["generated_tokens"], 0)
        print(f"test_streaming_response_is_returned: {response}")

    def test_blank_stream_raises_clear_error(self):
        with patch("huggingface_hub.InferenceClient", FakeBlankClient):
            with self.assertRaisesRegex(RuntimeError, "returned no visible text content"):
                generate_api_math_representation(
                    prompt="1 + 1",
                    generation_level="Highschool",
                    max_new_tokens=64,
                    temperature=0.7,
                    hf_token="fake-token",
                )

    def test_live_remote_model_when_hf_token_is_available(self):
        hf_token = os.getenv("HF_TOKEN")
        if not hf_token:
            self.skipTest("Set HF_TOKEN to run the live remote model test.")

        response, metrics = generate_api_math_representation(
            prompt="1 + 1",
            generation_level="Highschool",
            max_new_tokens=64,
            temperature=0.7,
            hf_token=hf_token,
        )
        print(f"test_live_remote_model_when_hf_token_is_available: {response}")

        self.assertTrue(response.strip())
        self.assertEqual(metrics["mode"], "api")
        self.assertEqual(metrics["model"], os.getenv("OSMS_REMOTE_MODEL_NAME", "openai/gpt-oss-20b"))


if __name__ == "__main__":
    unittest.main()
