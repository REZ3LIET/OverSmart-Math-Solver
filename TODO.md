# Recovery TODO

- Write the remote recovery/setup script invoked by `bash/external_watcher.sh`.
  It should clone or update the app, create or reuse the virtual environment,
  install dependencies, apply the required machine modifications, and start the
  app. It must be safe to run repeatedly.
- Optimize recovery time: use a shallow clone, pin/cache dependencies where
  possible, start remote inference first, and avoid blocking app startup on the
  local model download.
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
