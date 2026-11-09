import unittest
from types import SimpleNamespace
from unittest.mock import patch

from prometheus_client import REGISTRY

import app


class FakeProgress:
    def __call__(self, *_args, **_kwargs):
        pass


def metric_value(name, labels=None):
    return REGISTRY.get_sample_value(name, labels) or 0


class AppMetricsTest(unittest.TestCase):
    def test_model_download_runs_in_background(self):
        with patch.object(app, "download_local_model") as download, patch(
            "builtins.print"
        ):
            thread = app.start_background_model_download()
            thread.join(timeout=1)

        self.assertFalse(thread.is_alive())
        download.assert_called_once_with()

    def test_successful_local_request_updates_metrics(self):
        before = {
            "requests": metric_value("app_requests_total"),
            "successes": metric_value("app_successful_requests_total"),
            "failures": metric_value("app_failed_requests_total"),
            "durations": metric_value("app_request_duration_seconds_count"),
            "responses": metric_value(
                "app_model_responses_total", {"mode": "local"}
            ),
            "prompt_tokens": metric_value(
                "app_prompt_tokens_total", {"mode": "local"}
            ),
            "generated_tokens": metric_value(
                "app_generated_tokens_total", {"mode": "local"}
            ),
        }
        inference_metrics = {
            "model": "test-model",
            "mode": "local",
            "response_time_s": 0.1,
            "model_ready_time_s": 0.0,
            "generation_time_s": 0.1,
            "prompt_tokens": 2,
            "generated_tokens": 1,
            "reasoning_tokens": None,
            "tokens_per_s": 10.0,
            "peak_rss_mb": 10.0,
            "gpu_peak_allocated_mb": None,
        }

        with patch.object(
            app,
            "generate_math_representation",
            return_value=("$$2$$", inference_metrics),
        ), patch("builtins.print"):
            response, report = app.generate_response(
                "1 + 1",
                "Highschool",
                True,
                32,
                0.0,
                progress=FakeProgress(),
            )

        self.assertEqual(response, "$$2$$")
        self.assertIn("Inference Report", report)
        self.assertEqual(metric_value("app_requests_total"), before["requests"] + 1)
        self.assertEqual(
            metric_value("app_successful_requests_total"), before["successes"] + 1
        )
        self.assertEqual(metric_value("app_failed_requests_total"), before["failures"])
        self.assertEqual(
            metric_value("app_request_duration_seconds_count"),
            before["durations"] + 1,
        )
        self.assertEqual(
            metric_value("app_model_responses_total", {"mode": "local"}),
            before["responses"] + 1,
        )
        self.assertEqual(
            metric_value("app_prompt_tokens_total", {"mode": "local"}),
            before["prompt_tokens"] + 2,
        )
        self.assertEqual(
            metric_value("app_generated_tokens_total", {"mode": "local"}),
            before["generated_tokens"] + 1,
        )
        self.assertEqual(metric_value("app_active_requests"), 0)

    def test_successful_local_fallback_counts_as_success(self):
        successes_before = metric_value("app_successful_requests_total")
        failures_before = metric_value("app_failed_requests_total")
        inference_metrics = {
            "model": "test-model",
            "mode": "local",
            "response_time_s": 0.1,
            "model_ready_time_s": 0.0,
            "generation_time_s": 0.1,
            "prompt_tokens": 2,
            "generated_tokens": 1,
            "reasoning_tokens": None,
            "tokens_per_s": 10.0,
            "peak_rss_mb": 10.0,
            "gpu_peak_allocated_mb": None,
        }

        remote_error = RuntimeError("provider request failed")
        remote_error.response = SimpleNamespace(status_code=402)

        with patch.object(
            app,
            "generate_api_math_representation",
            side_effect=remote_error,
        ), patch.object(
            app,
            "generate_math_representation",
            return_value=("$$2$$", inference_metrics),
        ), patch("builtins.print"):
            response, report = app.generate_response(
                "1 + 1",
                "Highschool",
                False,
                32,
                0.0,
                hf_access_token="hf_test",
                progress=FakeProgress(),
            )

        self.assertEqual(response, "$$2$$")
        self.assertIn("Hugging Face Error 402: Payment Required", report)
        self.assertIn("Local Fallback Used", report)
        self.assertEqual(
            metric_value("app_successful_requests_total"), successes_before + 1
        )
        self.assertEqual(metric_value("app_failed_requests_total"), failures_before)

    def test_successful_remote_request_tracks_api_metrics(self):
        responses_before = metric_value(
            "app_model_responses_total", {"mode": "api"}
        )
        tokens_before = metric_value(
            "app_generated_tokens_total", {"mode": "api"}
        )
        inference_metrics = {
            "model": "test-api-model",
            "mode": "api",
            "response_time_s": 0.1,
            "model_ready_time_s": 0.0,
            "generation_time_s": 0.1,
            "prompt_tokens": 4,
            "generated_tokens": 2,
            "reasoning_tokens": None,
            "tokens_per_s": 20.0,
            "peak_rss_mb": 10.0,
            "gpu_peak_allocated_mb": None,
        }

        with patch.object(
            app,
            "generate_api_math_representation",
            return_value=("$$2$$", inference_metrics),
        ), patch("builtins.print"):
            app.generate_response(
                "1 + 1",
                "Highschool",
                False,
                32,
                0.0,
                hf_access_token="hf_test",
                progress=FakeProgress(),
            )

        self.assertEqual(
            metric_value("app_model_responses_total", {"mode": "api"}),
            responses_before + 1,
        )
        self.assertEqual(
            metric_value("app_generated_tokens_total", {"mode": "api"}),
            tokens_before + 2,
        )

    def test_handled_inference_failure_updates_failure_metric(self):
        requests_before = metric_value("app_requests_total")
        failures_before = metric_value("app_failed_requests_total")

        with patch.object(
            app,
            "generate_math_representation",
            side_effect=RuntimeError("model unavailable"),
        ), patch("builtins.print"):
            response, report = app.generate_response(
                "1 + 1",
                "Highschool",
                True,
                32,
                0.0,
                progress=FakeProgress(),
            )

        self.assertEqual(response, "")
        self.assertIn("Inference Failed", report)
        self.assertEqual(metric_value("app_requests_total"), requests_before + 1)
        self.assertEqual(metric_value("app_failed_requests_total"), failures_before + 1)


if __name__ == "__main__":
    unittest.main()
