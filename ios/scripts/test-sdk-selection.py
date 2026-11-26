#!/usr/bin/env python3
"""Real wrapper/child subprocess tests with a STUB SDK lookup, not native proof."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("with-sdk.sh")


class SDKSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.sdks = {}
        for name in ("MacOSX27.2", "iPhoneOS27.2", "iPhoneOS27.3",
                     "iPhoneSimulator27.2", "iPhoneSimulator27.3"):
            path = self.root / f"{name}.sdk"
            path.mkdir()
            (path / "SDKSettings.json").write_text(json.dumps({"Version": name[-4:]}))
            self.sdks[name] = str(path)
        lookup = self.root / "xcrun"
        lookup.write_text('''#!/bin/bash
set -eu
[[ -z "${SDKROOT+x}" ]]
[[ "$1" == --sdk && "$3" == --show-sdk-path ]]
printf '%s' "$2" > "$LOOKUP_RECEIPT"
printf '%s' "$LOOKUP_RESULT"
exit "$LOOKUP_STATUS"
''')
        lookup.chmod(0o755)

    def run_wrapper(self, target, inherited, result, status=0):
        env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                   LOOKUP_RECEIPT=str(self.root / "selection"),
                   LOOKUP_RESULT=result, LOOKUP_STATUS=str(status),
                   DEVELOPER_DIR="/Selected/Developer")
        env.pop("SDKROOT", None)
        if inherited is not None:
            env["SDKROOT"] = inherited
        child = 'printf "CHILD:%s:%s" "$SDKROOT" "$DEVELOPER_DIR"'
        return subprocess.run(["bash", str(SCRIPT), target, "bash", "-c", child],
                              env=env, capture_output=True, text=True)

    def test_target_selection_before_child_starts(self):
        mac = self.sdks["MacOSX27.2"]
        sim = self.sdks["iPhoneSimulator27.3"]
        device = self.sdks["iPhoneOS27.3"]
        old_sim = self.sdks["iPhoneSimulator27.2"]
        old_device = self.sdks["iPhoneOS27.2"]
        cases = [
            ("iphonesimulator", None, "iphonesimulator", sim),
            ("iphonesimulator", mac, "iphonesimulator", sim),
            ("iphoneos", mac, "iphoneos", device),
            ("iphonesimulator", old_sim, old_sim, old_sim),
            ("iphoneos", old_device, old_device, old_device),
            ("iphonesimulator", "iphonesimulator27.2", "iphonesimulator27.2", old_sim),
            ("macosx", sim, "macosx", mac),
            ("macosx", mac, mac, mac),
        ]
        for target, inherited, selected, resolved in cases:
            with self.subTest(target=target, inherited=inherited):
                result = self.run_wrapper(target, inherited, resolved)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"CHILD:{resolved}:/Selected/Developer")
                self.assertEqual((self.root / "selection").read_text(), selected)

    def test_invalid_selection_or_lookup_never_launches_child(self):
        sim = self.sdks["iPhoneSimulator27.3"]
        cases = [
            ("bogus", None, sim, 0),
            ("iphonesimulator", "iphonesimulator-garbage", sim, 0),
            ("iphonesimulator", "/Unknown.sdk", sim, 0),
            ("iphonesimulator", "relative/iPhoneSimulator27.2.sdk", sim, 0),
            ("iphonesimulator", None, sim, 7),
            ("iphonesimulator", None, "", 0),
            ("iphonesimulator", None, self.sdks["MacOSX27.2"], 0),
            ("iphonesimulator", None, "/missing/iPhoneSimulator27.3.sdk", 0),
        ]
        for target, inherited, resolved, status in cases:
            with self.subTest(target=target, inherited=inherited, resolved=resolved, status=status):
                result = self.run_wrapper(target, inherited, resolved, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("CHILD", result.stdout)
        (Path(sim) / "SDKSettings.json").unlink()
        result = self.run_wrapper("iphonesimulator", None, sim)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("CHILD", result.stdout)

    def test_directory_sdk_settings_never_launches_child(self):
        sim = self.sdks["iPhoneSimulator27.3"]
        settings = Path(sim) / "SDKSettings.json"
        settings.unlink()
        settings.mkdir()
        result = self.run_wrapper("iphonesimulator", None, sim)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertNotIn("CHILD", result.stdout)

    def test_missing_child_rejected(self):
        result = subprocess.run(["bash", str(SCRIPT), "iphonesimulator"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main(verbosity=2)
