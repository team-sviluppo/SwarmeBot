#!/usr/bin/env python3
"""Offline checks for curated release notes and credential-free update feeds."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_notes", ROOT / "scripts/release-notes.py")
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="swarme-notes-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "initial")
        self.git("tag", "v0.5.1")
        self.git("tag", "v0.5.2")
        self.git("tag", "v0.5.3")  # re-publishing still compares against 0.5.2
        self.git("tag", "v9.0.0")  # a newer version is not the previous version
        self.git("tag", "v0.5.3-beta")
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## [0.5.3]\n\n### Progetti\n\n- Cartelle con etichette.\n"
            "\n## [0.5.2]\n\n- An old change, not part of this release.\n", encoding="utf-8")
        self.output = self.root / "out"

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True)

    def test_exact_version_and_previous_release_in_both_formats(self):
        notes.prepare(self.root, "0.5.3", "team-sviluppo/SwarmeBot", self.output)
        markdown = (self.output / "release-notes.md").read_text()
        rendered = (self.output / "release-notes.html").read_text()
        for text in (markdown, rendered):
            self.assertIn("Differenze rispetto alla versione 0.5.2.", text)
            self.assertIn("Cartelle con etichette.", text)
            self.assertIn("/compare/v0.5.2...v0.5.3", text)
            self.assertNotIn("An old change", text)

    def test_missing_empty_and_duplicate_sections_fail(self):
        for changelog in ("## [0.5.2]\n- Old", "## [0.5.3]\n### TODO", "## [0.5.3]\n- One\n## [0.5.3]\n- Two"):
            with self.subTest(changelog=changelog), self.assertRaises(ValueError):
                notes.section(changelog, "0.5.3")

    def test_authored_markup_is_escaped_and_valid_inside_appcast(self):
        body = '### <script>\n\n- A & B ]]> <img src="bad">\n\nFirst paragraph.\nSecond line.'
        rendered = notes.render_html(body)
        self.assertNotIn("<script>", rendered)
        self.assertNotIn("<img", rendered)
        self.assertIn("A &amp; B ]]&gt;", rendered)
        self.assertIn("<p>First paragraph. Second line.</p>", rendered)
        item = ET.fromstring(f"<item><description><![CDATA[{rendered}]]></description></item>")
        self.assertEqual(item.findtext("description"), rendered)

    def test_first_release_has_no_comparison(self):
        self.assertIsNone(notes.previous_version(self.root, "0.1.0"))

    def test_unmerged_tags_are_not_used_as_previous_version(self):
        original = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--orphan", "other")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "other")
        self.git("tag", "v0.5.99")
        self.git("checkout", "--detach", original)
        self.assertEqual(notes.previous_version(self.root, "0.6.0"), "0.5.3")

    def test_invalid_version_and_credentialed_repository_are_rejected(self):
        for version, repo in (("../version", "owner/repo"), ("0.5.3", "user:password@github.com/repo")):
            with self.subTest(version=version, repo=repo), self.assertRaises(ValueError):
                notes.prepare(self.root, version, repo, self.output)

    def test_packaging_rejects_private_feed_overrides_before_building(self):
        for feed in ("https://user:secret@github.com/feed", "https://github.com/feed?token=secret", "http://github.com/feed", "https://github.com/feed#secret"):
            with self.subTest(feed=feed):
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/bundle-app.sh")],
                    env={**os.environ, "SPARKLE_FEED_URL": feed, "SIGN_IDENTITY": "-"},
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("public HTTPS URL", result.stderr)
                self.assertNotIn("secret", result.stdout + result.stderr)

    def pipeline(self, *, existing=False, visibility="PUBLIC"):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("release-mac.sh", "release-notes.py"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        # The release script is real. Only its external build/sign/publish commands are fake.
        for name, commands in {
            "bundle-app.sh": 'mkdir -p "$ROOT/build/SwarmeBot.app"; printf dmg > "$ROOT/build/SwarmeBot.dmg"',
            "linux-engines-manifest.sh": 'mkdir -p "$ROOT/build/linux/release"; printf engine > "$ROOT/build/linux/release/swarme-harness-linux-aarch64"',
        }.items():
            path = scripts / name
            path.write_text('#!/bin/bash\nset -eu\nROOT="$(cd "$(dirname "$0")/.." && pwd)"\n' + commands + "\n")
            path.chmod(0o755)
        commands = self.root / "commands"
        commands.mkdir()
        real_git = shutil.which("git")
        mock = commands / "mock"
        mock.write_text(f"#!{os.sys.executable}\n" + textwrap.dedent('''\
            import json, os
            from pathlib import Path
            import subprocess, sys
            name = Path(sys.argv[0]).name
            args = sys.argv[1:]
            with open(os.environ["QA_COMMAND_LOG"], "a") as log:
                log.write(json.dumps([name] + args) + "\\n")
            if name == "git":
                actual = args[2:] if args[:1] == ["-C"] else args
                if actual[0] in ("push", "ls-remote"):
                    sys.exit(0)
                sys.exit(subprocess.run([os.environ["QA_REAL_GIT"]] + args).returncode)
            elif name == "uname": print("Darwin")
            elif name == "security": print('1) TEST "Developer ID Application: Test"')
            elif name == "codesign": print("Authority=Developer ID Application: Test\\nflags=0x10000(runtime)", file=sys.stderr)
            elif name == "sign_update": print('sparkle:edSignature="fixture-signature"')
            elif name == "ditto": Path(args[-1]).write_bytes(b"archive")
            elif name == "stat": print(Path(args[-1]).stat().st_size)
            elif name == "gh":
                if args[:2] == ["repo", "view"]: print(os.environ["QA_VISIBILITY"])
                elif args[:2] == ["release", "view"]: sys.exit(int(os.environ["QA_EXISTING_RELEASE"] != "1"))
            '''))
        mock.chmod(0o755)
        for name in ("git", "uname", "security", "codesign", "sign_update", "ditto", "stat", "gh"):
            (commands / name).symlink_to(mock)
        log = self.root / "commands.jsonl"
        # Do not pass the publisher's actual signing/notarization credentials to the simulation.
        env = {"PATH": str(commands) + os.pathsep + os.environ["PATH"],
               "MAC_SIGN_IDENTITY": "Developer ID Application: Test", "SPARKLE_PUBLIC_KEY": "fixture-public-key",
               "SKIP_LINUX_ENGINES": "1", "QA_COMMAND_LOG": str(log), "QA_REAL_GIT": real_git,
               "QA_VISIBILITY": visibility, "QA_EXISTING_RELEASE": "1" if existing else "0"}
        result = subprocess.run(["bash", str(scripts / "release-mac.sh"), "--version", "0.5.3", "--skip-notarize"],
                                env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    def test_release_creation_publishes_curated_notes_and_same_appcast_content(self):
        result, calls = self.pipeline()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        create = next(call for call in calls if call[:3] == ["gh", "release", "create"])
        markdown = Path(create[create.index("--notes-file") + 1]).read_text()
        self.assertIn("Cartelle con etichette.", markdown)
        self.assertIn("0.5.2...v0.5.3", markdown)
        appcast = ET.parse(self.root / "release/appcast.xml")
        description = appcast.findtext("./channel/item/description")
        self.assertEqual(description, (self.root / "release/release-notes.html").read_text().rstrip("\n"))
        self.assertEqual(appcast.find("./channel/item/enclosure").get("url"),
                         "https://github.com/team-sviluppo/SwarmeBot/releases/download/v0.5.3/SwarmeBot-0.5.3-arm64.zip")

    def test_republishing_updates_the_existing_release_notes(self):
        result, calls = self.pipeline(existing=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        edit = next(call for call in calls if call[:3] == ["gh", "release", "edit"])
        self.assertIn("--notes-file", edit)
        self.assertFalse(any(call[:3] == ["gh", "release", "create"] for call in calls))

    def test_private_release_repository_fails_before_signing_or_publication(self):
        result, calls = self.pipeline(visibility="PRIVATE")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public GitHub repository", result.stderr)
        self.assertFalse(any(call[0] in ("security", "codesign", "sign_update") for call in calls))
        self.assertFalse(any(call[:2] == ["gh", "release"] for call in calls))


if __name__ == "__main__":
    unittest.main()
