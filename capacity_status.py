import os
from pathlib import Path


DEFAULT_CAPACITY_FILE = Path(
    os.getenv("OSMS_CAPACITY_FILE", "~/.check/capacity")
).expanduser()

NEAR_CAPACITY_MESSAGE = (
    "### ⚠️ System near capacity\n\n"
    "The system is currently operating near capacity. Responses may take longer."
)


def capacity_message(capacity_file: Path | str | None = None) -> str:
    """Return the UI warning while the watcher reports a threshold violation."""
    path = Path(capacity_file).expanduser() if capacity_file else DEFAULT_CAPACITY_FILE
    try:
        return NEAR_CAPACITY_MESSAGE if path.is_file() else ""
    except OSError:
        return ""

