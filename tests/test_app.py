import importlib
import os
import sys
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import patch


fake_types = ModuleType("google.genai.types")
fake_types.GenerateContentConfig = lambda **kwargs: SimpleNamespace(**kwargs)
fake_types.ThinkingConfig = lambda **kwargs: SimpleNamespace(**kwargs)
fake_types.ThinkingLevel = SimpleNamespace(LOW="low")

fake_genai = ModuleType("google.genai")
fake_genai.types = fake_types
client_kwargs = {}


def fake_client(**kwargs):
    client_kwargs.update(kwargs)
    return SimpleNamespace(models=None)


fake_genai.Client = fake_client

fake_google = ModuleType("google")
fake_google.__path__ = []
fake_google.genai = fake_genai

with patch.dict(os.environ, {"GEMINI_API_KEY": "test-key"}), patch.dict(
    sys.modules,
    {
        "google": fake_google,
        "google.genai": fake_genai,
        "google.genai.types": fake_types,
    },
):
    app = importlib.import_module("app")


class FakeModels:
    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.calls = []

    def generate_content(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error
        return SimpleNamespace(text=self.response)


class AppTest(unittest.TestCase):
    def test_client_uses_api_key(self):
        self.assertEqual(
            client_kwargs,
            {"enterprise": True, "api_key": "test-key"},
        )

    def test_generate_response_uses_gemini_model(self):
        models = FakeModels(response="$$2$$")
        app.client = SimpleNamespace(models=models)

        response = app.generate_response("1 + 1", "Highschool", 128)

        self.assertEqual(response, "$$2$$")
        self.assertEqual(models.calls[0]["model"], app.GEMINI_MODEL)
        self.assertEqual(models.calls[0]["contents"], "1 + 1")
        self.assertEqual(models.calls[0]["config"].max_output_tokens, 128)
        self.assertIn(
            "high-school mathematics",
            models.calls[0]["config"].system_instruction,
        )

    def test_generate_response_reports_gemini_api_error(self):
        app.client = SimpleNamespace(
            models=FakeModels(error=RuntimeError("permission denied\nprivate detail"))
        )

        response = app.generate_response("1 + 1", "Highschool", 128)

        self.assertEqual(response, "### Gemini API Error\n\npermission denied")

    def test_blank_prompt_skips_model(self):
        models = FakeModels(response="unused")
        app.client = SimpleNamespace(models=models)

        self.assertEqual(app.generate_response("  ", "Highschool", 128), "")
        self.assertEqual(models.calls, [])


if __name__ == "__main__":
    unittest.main()

