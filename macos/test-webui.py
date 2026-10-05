#!/usr/bin/env python3

import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "WebUI"))

from vivid_webui_server import list_projects, wallpaper_engine_project_roots


class CatalogDeduplicationTests(unittest.TestCase):
    def test_case_and_alias_variants_are_scanned_once(self):
        with tempfile.TemporaryDirectory(prefix="vivid-catalog-test-") as temporary:
            root = pathlib.Path(temporary)
            install = root / "steamapps" / "common" / "wallpaper_engine"
            workshop = root / "steamapps" / "workshop" / "content" / "431960"
            project = workshop / "123456"
            install.mkdir(parents=True)
            project.mkdir(parents=True)
            (project / "project.json").write_text(
                json.dumps({"type": "video", "file": "wallpaper.mp4"}),
                encoding="utf-8",
            )
            (project / "wallpaper.mp4").write_bytes(b"fixture")

            self._alias(root / "Steamapps", root / "steamapps")
            self._alias(root / "steamapps" / "Workshop", root / "steamapps" / "workshop")
            self._alias(
                root / "steamapps" / "workshop" / "Content",
                root / "steamapps" / "workshop" / "content",
            )

            roots = wallpaper_engine_project_roots(str(root))
            projects = list_projects(str(root))

            self.assertEqual(len(roots), 1, roots)
            self.assertEqual(len(projects), 1, projects)
            self.assertEqual(projects[0]["basename"], "123456")

    @staticmethod
    def _alias(alias, target):
        if not alias.exists():
            alias.symlink_to(target, target_is_directory=True)


if __name__ == "__main__":
    unittest.main()
