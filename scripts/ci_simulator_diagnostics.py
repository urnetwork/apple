#!/usr/bin/env python3
"""Publish only repository test names, source locations and finite failure classes.

xcresult assertion values, messages, log text and attachments stay private.
GitHub check annotations remain readable even when artifact downloads and job
summaries require authentication. This diagnostic never changes the test result.
"""
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time
from urllib.parse import unquote, urlsplit, parse_qs

MAX_BYTES = 2 * 1024 * 1024
MAX_NODES = 20000
MAX_FAILURES = 20
TOOL_TIMEOUT = 30
CLASSES = (
    ("timeout", r"timed?\s*out|timeout|unfulfilled expectation"),
    ("assertion", r"assertion|XCTAssert|expectation failed|XCTFail"),
    ("concurrency", r"main.actor|sendable|actor.isolated|data.race"),
    ("typecheck", r"cannot convert|cannot find|no member|missing argument|extra argument|ambiguous|type.check"),
    ("linker", r"linker|undefined symbols|symbol.*not found|duplicate symbol"),
    ("crash", r"crash|signal (?:[0-9]+|SIG)|abort|EXC_BAD|fatal error"),
    ("simulator", r"simulator|failed to launch|failed to install|booted|destination"),
    ("test_runner", r"test runner|testing failed|test session|test bundle"),
)
FAILURE_KEYS = {"testfailures", "failures", "errors", "errorsummaries", "testfailuresummaries"}
IDENTIFIER_KEYS = {"testIdentifierString", "testIdentifier", "testIdentifierURL", "testName", "nodeIdentifier", "nodeIdentifierURL", "name"}


def repository_catalog(root):
    files = {}
    tests = set()
    for path in sorted((root / "app").rglob("*.swift")):
        if "build" in path.relative_to(root).parts or path.stat().st_size > MAX_BYTES:
            continue
        relative = path.relative_to(root).as_posix()
        if not re.fullmatch(r"[A-Za-z0-9_./ -]+\.swift", relative):
            continue
        files.setdefault(path.name, []).append(relative)
        if "networkTests" in path.parts:
            tests.update(re.findall(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", path.read_text()))
    return files, tests


def collect_fields(node):
    """Bound traversal; emit no source text from this helper."""
    todo = [node]
    values = []
    visited = 0
    while todo:
        current = todo.pop()
        visited += 1
        if visited > MAX_NODES:
            raise ValueError("node bound")
        if isinstance(current, dict):
            for key, value in current.items():
                if isinstance(value, str):
                    values.append((key, value))
                elif type(value) is int:
                    values.append((key, value))
                elif isinstance(value, (dict, list)):
                    todo.append(value)
        elif isinstance(current, list):
            todo.extend(current)
    return values


def project_failure(node, catalog):
    files, allowed_tests = catalog
    fields = collect_fields(node)
    texts = [value for key, value in fields if isinstance(value, str)]
    classes = [name for name, pattern in CLASSES if any(re.search(pattern, text, re.I) for text in texts)]
    tests = set()
    for key, value in fields:
        if key in IDENTIFIER_KEYS and isinstance(value, str):
            tests.update(set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", unquote(value))) & allowed_tests)
    locations = set()
    for key, value in fields:
        if key not in ("url", "sourceURL", "sourceUrl", "filePath", "fileName", "documentLocationInCreatingWorkspace", "sourceFilePath") or not isinstance(value, str):
            continue
        parsed = urlsplit(value)
        path = unquote(parsed.path)
        basename = Path(path).name
        match = re.fullmatch(r"(.+\.swift)(?::([0-9]+)(?::[0-9]+)?)?", basename)
        if not match:
            continue
        candidates = files.get(match[1], [])
        if len(candidates) != 1:
            continue
        line = int(match[2]) if match[2] else None
        fragment = parse_qs(parsed.fragment)
        for k in ("StartingLineNumber", "line"):
            if k in fragment and re.fullmatch(r"[0-9]{1,7}", fragment[k][0]):
                line = int(fragment[k][0])
        if line is None:
            line = next((v for k, v in fields if k in ("lineNumber", "line") and type(v) is int and 0 < v <= 1000000), None)
        if line is not None and not 0 < line <= 1000000:
            line = None
        locations.add((candidates[0], line))
    return {"classes": classes or ["unclassified"], "tests": sorted(tests)[:4],
            "locations": [{"path": p, "line": line} for p, line in sorted(locations, key=repr)[:2]]}


def project(document, catalog):
    if not isinstance(document, (dict, list)):
        raise ValueError("document shape")
    failures = []
    todo = [(document, False)]
    visited = 0
    while todo:
        node, failing = todo.pop()
        visited += 1
        if visited > MAX_NODES:
            raise ValueError("node bound")
        if isinstance(node, dict):
            status = next((node[k] for k in ("result", "testStatus", "status") if k in node), None)
            identifies_test = any(key in node for key in IDENTIFIER_KEYS - {"name"}) or node.get("nodeType") in ("Test Case", "Test Case Run")
            failing = failing or (identifies_test and isinstance(status, str) and status.lower() in ("failed", "failure"))
            if failing:
                failures.append(project_failure(node, catalog))
                if len(failures) == MAX_FAILURES:
                    break
            else:
                for key, value in node.items():
                    if isinstance(value, (dict, list)):
                        todo.append((value, key.lower() in FAILURE_KEYS))
        elif isinstance(node, list):
            todo.extend((value, failing) for value in reversed(node))
    counts = {}
    if isinstance(document, dict):
        for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures", "errorCount", "warningCount"):
            value = document.get(key)
            if type(value) is int and 0 <= value <= 1000000:
                counts[key] = value
    return {"counts": counts, "failures": failures, "failure_limit_reached": len(failures) == MAX_FAILURES}


def bounded_xcresult(command, bundle):
    process = subprocess.Popen(["xcrun", "xcresulttool", "get", *command, "--path", str(bundle), "--compact"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + TOOL_TIMEOUT
    result = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise TimeoutError("tool deadline")
                for key, _ in selector.select(.1):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                    result.extend(data)
                    if len(result) > MAX_BYTES:
                        raise ValueError("tool output bound")
        if process.wait(timeout=max(.001, deadline - time.monotonic())) != 0:
            raise ValueError("tool exit")
        return json.loads(result)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=1)
        process.stdout.close()


def annotation(text):
    # All interpolated data has already been reduced to public source names,
    # numeric counts and fixed enums. Escape GitHub command delimiters anyway.
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::warning title=Simulator failure diagnostic::" + text)


def main():
    root = Path(__file__).resolve().parents[1]
    bundle = root / "app/build/networkTests.xcresult"
    if not bundle.is_dir():
        annotation("result_bundle=absent; original test step remains authoritative")
        return
    catalog = repository_catalog(root)
    for title, command in (("tests", ["test-results", "summary"]), ("build", ["build-results"])):
        try:
            result = project(bounded_xcresult(command, bundle), catalog)
            annotation(title + ": " + json.dumps(result, sort_keys=True, separators=(",", ":")))
            summary = os.environ.get("GITHUB_STEP_SUMMARY")
            if summary:
                with open(summary, "a") as handle:
                    handle.write("\n### Sanitized simulator " + title + " diagnostics\n\n```json\n" + json.dumps(result, indent=2) + "\n```\n")
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError):
            annotation(title + ": diagnostic=unavailable; original test step remains authoritative")


if __name__ == "__main__":
    main()
