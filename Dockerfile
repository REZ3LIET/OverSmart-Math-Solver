FROM python:3.10-slim

WORKDIR /opt/app
COPY . .

# Install packages that we need. vim is for helping with debugging
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && \
apt-get upgrade -y ca-certificates && \
apt-get install -y --no-install-recommends \
prometheus-node-exporter \
&& rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir -r /opt/app/requirements.txt

EXPOSE 7860
EXPOSE 8000
EXPOSE 9100
ENV GRADIO_SERVER_NAME="0.0.0.0"

CMD bash -c "prometheus-node-exporter --web.listen-address=':9100' & python /opt/app/app.py"
