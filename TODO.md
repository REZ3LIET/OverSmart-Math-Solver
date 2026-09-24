# Recovery TODO

- Optimize recovery time: use a shallow clone, pin/cache dependencies where
  possible, start remote inference first, and avoid blocking app startup on the
  local model download.
- Optimize application cold start and dependency installation. Investigate a
  prebuilt virtual environment or container image, a persistent pip/model cache,
  a smaller dependency set, and lazy-loading large libraries so a rebuilt LXC
  does not download everything before Gradio can become healthy.
- Investigate local inference: confirm that selecting the local model calls the
  local inference path, verify that the configured model is downloaded, record
  its cache location and download errors, and add a clear UI/status indication
  while the model is downloading or loading.
- Add a lightweight application health endpoint and measure recovery time from
  the first failed check until that endpoint becomes healthy.
- Decide how the recovered app process will be supervised (`systemd`, a user
  service, or a PID-file/`nohup` approach based on available permissions).
- If cloned machines share server SSH host keys, regenerate those host keys too.
- Update the external watcher's trusted `known_hosts` entry safely when a rebuilt
  machine receives a new SSH host key.
- Decide how secrets required by the app will be supplied during recovery
  without committing them to the repository or printing them in logs.
- Add notifications for recovery attempts that continue to fail.
