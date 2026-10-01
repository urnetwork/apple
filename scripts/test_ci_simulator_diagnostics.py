import json
from pathlib import Path
import tempfile
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
import ci_simulator_diagnostics as d

CATALOG = ({"PickerTests.swift": ["app/networkTests/PickerTests.swift"]}, {"testHeldStatus", "testStaleQuery"})

class Diagnostics(unittest.TestCase):
    def test_failed_identifiers_are_public_source_names_only(self):
        data = {"totalTestCount": 30, "failedTests": 1, "testFailures": [{
            "testIdentifierString": "PickerTests/testHeldStatus()", "targetName": "private-target",
            "failureText": "XCTAssertEqual failed: secret-token != private-customer-data"}]}
        result = d.project(data, CATALOG)
        self.assertEqual(result["counts"], {"totalTestCount": 30, "failedTests": 1})
        self.assertEqual(result["failures"][0]["tests"], ["testHeldStatus"])
        self.assertEqual(result["failures"][0]["classes"], ["assertion"])
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("private", json.dumps(result))

    def test_identifier_url_and_source_location(self):
        data = {"testFailures": [{"testIdentifierURL": "test://opaque/private-target/PickerTests/testStaleQuery()",
                  "sourceCodeContext": {"location": {"filePath": "/private/checkouts/app/networkTests/PickerTests.swift", "lineNumber": 27}},
                  "failureText": "Exceeded timeout"}]}
        failure = d.project(data, CATALOG)["failures"][0]
        self.assertEqual(failure["tests"], ["testStaleQuery"])
        self.assertEqual(failure["locations"], [{"path": "app/networkTests/PickerTests.swift", "line": 27}])
        self.assertEqual(failure["classes"], ["timeout"])

    def test_compile_location_and_fixed_category_without_message(self):
        data = {"errors": [{"message": "cannot convert private-secret to expected type", "url": "file:///private/PickerTests.swift#StartingLineNumber=12&StartingColumnNumber=4"}]}
        failure = d.project(data, CATALOG)["failures"][0]
        self.assertEqual(failure["classes"], ["typecheck"])
        self.assertEqual(failure["locations"][0]["line"], 12)
        self.assertNotIn("private", json.dumps(failure))

    def test_nonfailures_and_arbitrary_names_are_not_published(self):
        data = {"warnings": [{"testIdentifier": "testHeldStatus()"}], "tests": [{"status": "Passed", "testName": "testStaleQuery"}], "testFailures": [{"testName": "customer_credential_abcdef", "failureText": "private-value"}]}
        result = d.project(data, CATALOG)
        self.assertEqual(len(result["failures"]), 1)
        self.assertEqual(result["failures"][0], {"classes": ["unclassified"], "tests": [], "locations": []})

    def test_status_failure_and_unknown_schema_are_explicit(self):
        data = {"result": "Failed", "tests": [{"result": "Failed", "nodeType": "Test Case", "name": "testHeldStatus()", "children": []}]}
        self.assertEqual(d.project(data, CATALOG)["failures"][0]["tests"], ["testHeldStatus"])
        self.assertEqual(d.project({"unknown": "secret"}, CATALOG), {"counts": {}, "failures": [], "failure_limit_reached": False})

    def test_limits_bool_and_unowned_source_path(self):
        data = {"failedTests": True, "totalTestCount": -1, "testFailures": [{"filePath": "/private/Unknown.swift", "lineNumber": 3}] * 50}
        result = d.project(data, CATALOG)
        self.assertEqual(result["counts"], {})
        self.assertEqual(len(result["failures"]), d.MAX_FAILURES)
        self.assertTrue(result["failure_limit_reached"])
        self.assertTrue(all(f["locations"] == [] for f in result["failures"]))
        with patch.object(d, "MAX_NODES", 1):
            with self.assertRaises(ValueError):
                d.project({"unknown": {"nested": []}}, CATALOG)

    def test_annotation_escapes_command_injection(self):
        with patch("builtins.print") as emit:
            d.annotation("fixed%\r\n::error::value")
        self.assertEqual(emit.call_args.args[0], "::warning title=Simulator failure diagnostic::fixed%25%0D%0A::error::value")

    def test_repository_catalog_excludes_build_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "app/networkTests").mkdir(parents=True)
            (root / "app/networkTests/PickerTests.swift").write_text("func testHeldStatus() {}")
            (root / "app/build").mkdir()
            (root / "app/build/Secret.swift").write_text("func privateValue() {}")
            files, tests = d.repository_catalog(root)
            self.assertEqual(files, CATALOG[0])
            self.assertEqual(tests, {"testHeldStatus"})

    def test_workflow_keeps_original_failure_and_uses_annotations(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/build-and-test.yml").read_text()
        step = workflow[workflow.index("      - name: Summarize failed simulator tests"):]
        self.assertIn("if: failure()", step)
        self.assertIn("continue-on-error: true", step)
        self.assertIn("timeout-minutes: 2", step)
        self.assertIn("python3 apple/scripts/ci_simulator_diagnostics.py", step)
        self.assertNotIn("result.stdout", step)

    def invoke_local_tool(self, code):
        original = subprocess.Popen
        def launch(argv, **kwargs):
            self.assertEqual(argv[:3], ["xcrun", "xcresulttool", "get"])
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            return original([sys.executable, "-c", code], **kwargs)
        with patch.object(d.subprocess, "Popen", side_effect=launch):
            return d.bounded_xcresult(["test-results", "summary"], Path("fixture.xcresult"))

    def test_actual_bounded_child_decodes_without_stderr_output(self):
        result = self.invoke_local_tool('import sys;sys.stderr.write("private-error");print(\'{"failedTests":1}\')')
        self.assertEqual(result, {"failedTests": 1})

    def test_actual_child_output_bound(self):
        with patch.object(d, "MAX_BYTES", 64):
            with self.assertRaises(ValueError):
                self.invoke_local_tool('print("x"*4096)')

    def test_actual_child_deadline_kills_owner(self):
        began = time.monotonic()
        with patch.object(d, "TOOL_TIMEOUT", .1):
            with self.assertRaises(TimeoutError):
                self.invoke_local_tool('import time;time.sleep(30)')
        self.assertLess(time.monotonic() - began, 2)

if __name__ == "__main__":
    unittest.main()
