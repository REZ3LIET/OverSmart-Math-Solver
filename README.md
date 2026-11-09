---
title: OverSmart-Math-Solver
emoji: 🧮
colorFrom: red
colorTo: purple
sdk: gradio
sdk_version: 6.5.1
app_file: app.py
pinned: false
hf_oauth: true
hf_oauth_scopes:
  - inference-api
license: apache-2.0
---
# OverSmart-Math-Solver
OSMS: OverSmart Math Solver

*Note: Codes are generated with help of Codex and designed by REZ3LIET!*  
Demo at [world-level](https://boxer-buffoon-unpiloted.ngrok-free.dev/)

## Docker deployment

The deployment uses the published Docker Hub images and a shared `monitoring`
network so that containers can reach each other by name. Create the network
once; skip this command if it already exists.

```bash
docker network create monitoring
```

### Application

```bash
docker run -d \
  --name group15_osms \
  -p 3131:7860 \
  --network monitoring \
  rez3liet/osms
```

The application is available at `http://localhost:3131`. The same container
serves Prometheus application metrics on port `8000` and Node Exporter metrics
on port `9100` within the Docker network. Add `-e HF_TOKEN='<token>'` before the
image name if the container should use a server-side Hugging Face token.

### Prometheus

```bash
docker run -d \
  --name group15_osms_prometheus \
  -p 3133:9090 \
  --network monitoring \
  rez3liet/osms_prometheus
```

Prometheus is available at `http://localhost:3133` and scrapes
`group15_osms:8000` and `group15_osms:9100`.

### Grafana

```bash
docker run -d \
  --name group15_osms_grafana \
  -p 3135:3000 \
  --network monitoring \
  -e GF_SECURITY_ADMIN_USER='<grafana-admin-user>' \
  -e GF_SECURITY_ADMIN_PASSWORD='<grafana-admin-password>' \
  rez3liet/osms_grafana
```

Grafana is available at `http://localhost:3135`. Configure its Prometheus data
source URL as `http://group15_osms_prometheus:9090`, then import
`Grafana/osms-dashboard.json`.

### SSH tunnels for monitoring

Run these commands on the local machine to access Prometheus and Grafana on the
remote server. Replace `key` with the SSH private-key path.

```bash
ssh -i key -f -N -L 3133:localhost:3133 -p 2222 group15@melnibone.wpi.edu
ssh -i key -f -N -L 3135:localhost:3135 -p 2222 group15@melnibone.wpi.edu
```

After creating the tunnels, open Prometheus at `http://localhost:3133` and
Grafana at `http://localhost:3135`.

### ngrok

```bash
docker run -d \
  --name group15_osms_ngrok \
  --restart unless-stopped \
  --network monitoring \
  -e NGROK_AUTHTOKEN='<ngrok-auth-token>' \
  rez3liet/osms_ngrok \
  http://group15_osms:7860 \
  --url https://boxer-buffoon-unpiloted.ngrok-free.dev \
  --log stdout
```

The ngrok container publishes the application at the configured HTTPS URL. To
confirm the active tunnel or troubleshoot startup, run:

```bash
docker logs group15_osms_ngrok
```
