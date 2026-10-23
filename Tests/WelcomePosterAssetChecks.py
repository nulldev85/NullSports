"""Bundled first-launch artwork must be real, complete and reproducible offline."""
import hashlib
import json
from pathlib import Path
import unittest
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def jpeg_size(data):
    if not data.startswith(b"\xff\xd8"):
        raise ValueError("Not a JPEG")
    index = 2
    while index + 8 < len(data):
        if data[index] != 0xFF:
            raise ValueError("Invalid JPEG marker")
        while data[index] == 0xFF:
            index += 1
        marker = data[index]
        index += 1
        length = int.from_bytes(data[index:index + 2], "big")
        if marker in (0xC0, 0xC1, 0xC2):
            height = int.from_bytes(data[index + 3:index + 5], "big")
            width = int.from_bytes(data[index + 5:index + 7], "big")
            return width, height
        if length < 2:
            raise ValueError("Invalid JPEG segment")
        index += length
    raise ValueError("JPEG has no frame")


class WelcomePosterAssetChecks(unittest.TestCase):
    def test_twelve_official_posters_are_present_and_intact(self):
        posters = json.loads((ROOT / "BuildAssets/WelcomePosters.json").read_text())
        self.assertEqual([p["asset"] for p in posters], [f"WelcomePoster{i:02d}" for i in range(1, 13)])
        self.assertEqual([p["kind"] for p in posters], ["movie", "tv"] * 6)
        self.assertEqual(len({p["sha256"] for p in posters}), 12)
        total_bytes = 0
        for poster in posters:
            with self.subTest(title=poster["title"]):
                source = urlparse(poster["source"])
                self.assertEqual((source.scheme, source.netloc), ("https", "image.tmdb.org"))
                self.assertTrue(source.path.startswith("/t/p/w342/"))
                self.assertGreater(poster["tmdbID"], 0)
                folder = ROOT / "iPhone/Assets.xcassets" / f"{poster['asset']}.imageset"
                contents = json.loads((folder / "Contents.json").read_text())
                self.assertEqual(contents["images"], [{"filename": "poster.jpg", "idiom": "universal"}])
                data = (folder / "poster.jpg").read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), poster["sha256"])
                self.assertEqual(jpeg_size(data), (342, 513))
                total_bytes += len(data)
        self.assertLess(total_bytes, 1_048_576, "Welcome posters should add less than 1MB")


if __name__ == "__main__":
    unittest.main()
