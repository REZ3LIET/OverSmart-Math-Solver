# OverSmart-Math-Solver

OSMS: OverSmart Math Solver

*Codes are generated with help from Codex and designed by REZ3LIET.*

Demo: [world-level](https://boxer-buffoon-unpiloted.ngrok-free.dev/)

## Model execution

The application calls `gemini-3.5-flash` through the Gemini Developer API.

Create the local environment file and add your Gemini API key:

```bash
cp .env.example .env
# Edit .env and replace GEMINI_API_KEY with the real key.
```

For a direct local run, export the values from `.env` into your shell first:

```bash
set -a
. ./.env
set +a
pip install -r requirements.txt
python app.py
```

To make one model request without starting Gradio, run `python gcp_test.py`
after exporting the same environment variables.

The Gradio application listens on port `7860` by default.

## Docker deployment

Create a shared network for the application and ngrok containers:

```bash
docker network create osms
```

Run the application using the variables in `.env`:

```bash
docker run -d \
  --name group15_osms \
  --restart unless-stopped \
  --network osms \
  -p 3131:7860 \
  --env-file .env \
  rez3liet/osms
```

The `.env` file is read by Docker at startup and is not copied into the image.
For a shared deployment, inject `GEMINI_API_KEY` from the cloud platform's
secret manager instead of uploading `.env`.

Run ngrok on the same network:

```bash
docker run -d \
  --name group15_osms_ngrok \
  --restart unless-stopped \
  --network osms \
  -e NGROK_AUTHTOKEN='<ngrok-auth-token>' \
  rez3liet/osms_ngrok \
  http://group15_osms:7860 \
  --url https://boxer-buffoon-unpiloted.ngrok-free.dev \
  --log stdout
```

Inspect the public-tunnel logs with:

```bash
docker logs group15_osms_ngrok
```
