"""Check generated archive paths without invoking Xcode or signing tools."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ArchiveOutputs(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="apple-archive-outputs-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        shutil.copyfile(ROOT / ".gitignore", self.root / ".gitignore")
        self.write("app/ExportOptions-DeveloperID.plist", "tracked signing configuration")
        self.git("init", "-q")
        self.git("config", "user.name", "Archive Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "core.excludesFile", "/dev/null")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture sealed source")

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.root), *args], check=check,
                              capture_output=True, text=True, timeout=15)

    def write(self, relative, value):
        file = self.root / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value)

    def test_canonical_store_and_direct_archives_are_generated_outputs(self):
        for archive in ("build.xcarchive", "build-direct.xcarchive"):
            for output in ("Info.plist", "Products/Applications/URnetwork.app/Contents/MacOS/URnetwork"):
                relative = f"app/{archive}/{output}"
                self.write(relative, "generated archive output")
                self.assertEqual(self.git("check-ignore", "--no-index", relative, check=False).returncode, 0, relative)
        self.assertEqual(self.git("status", "--porcelain=v1", "--untracked-files=all").stdout, "")

    def test_adjacent_and_tracked_signing_inputs_still_change_source(self):
        for relative in ("app/new.swift", "app/build-direct.xcarchive-notes/source.swift",
                         "app/another/build-direct.xcarchive/source.swift"):
            self.write(relative, "new source")
            self.assertEqual(self.git("check-ignore", "--no-index", relative, check=False).returncode, 1, relative)
        tracked = "app/ExportOptions-DeveloperID.plist"
        self.write(tracked, "changed signing configuration")
        self.assertIn(tracked, self.git("diff", "--name-only", "HEAD").stdout)
        self.git("add", tracked)
        self.assertIn(tracked, self.git("diff", "--cached", "--name-only").stdout)


if __name__ == "__main__":
    unittest.main()
