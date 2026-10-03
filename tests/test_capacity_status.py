import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from capacity_status import NEAR_CAPACITY_MESSAGE, capacity_message


class CapacityStatusTest(unittest.TestCase):
    def test_warning_tracks_capacity_file(self):
        with tempfile.TemporaryDirectory() as directory:
            capacity_file = Path(directory) / "capacity"
            self.assertEqual(capacity_message(capacity_file), "")

            capacity_file.write_text("near-capacity\n", encoding="utf-8")
            self.assertEqual(
                capacity_message(capacity_file),
                NEAR_CAPACITY_MESSAGE,
            )

            capacity_file.unlink()
            self.assertEqual(capacity_message(capacity_file), "")


if __name__ == "__main__":
    unittest.main()
