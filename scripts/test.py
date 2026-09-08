#!/usr/bin/env python3
"""Run portable checks, or the full local iOS regression suite."""
import argparse
import http.server
import os
import threading
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def run(name, command, directory, cwd=ROOT, env=None):
    log = directory / f"{name}.log"
    print(f"Running {name}. Log: {log}", flush=True)
    with log.open("w") as stream:
        process = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    if process.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-35:]))
        raise RuntimeError(f"{name} failed with exit {process.returncode}")
    print(f"Passed {name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable", action="store_true", help="Run repository and Python checks only")
    parser.add_argument("--simulator", help="Use this existing simulator UUID, without erasing or deleting it")
    parser.add_argument("--base", help="Check commit messages in BASE..HEAD")
    parser.add_argument("--output", type=Path, help="New directory for logs and result bundles")
    args = parser.parse_args()
    directory = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="precinct-tests-"))
    if args.output:
        directory.mkdir(parents=True, exist_ok=False)
    print(f"Results: {directory}", flush=True)
    appearance_server = None
    simulator = None
    created = False
    database = ROOT / "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite"
    original_hash = None
    try:
        command = [sys.executable, "scripts/check_repository.py"]
        if args.base:
            command += ["--base", args.base]
        run("repository", command, directory)
        run("repository-tests", [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py", "-v"], directory)
        run("pipeline", [sys.executable, "-m", "unittest", "discover", "-s", "pipeline", "-p", "*test*.py", "-v"], directory)
        run("whitespace", ["git", "diff", "--check"], directory)
        if args.portable:
            print("Portable checks passed. iOS app, widget and bundled database were not tested.")
            return 0
        if sys.platform != "darwin" or not shutil.which("xcodegen") or not shutil.which("xcodebuild"):
            raise RuntimeError("Full checks require macOS, Xcode and XcodeGen. See TESTING.md.")
        if not database.is_file():
            raise RuntimeError(f"Required local bundled database is missing: {database}")
        original_hash = hashlib.sha256(database.read_bytes()).hexdigest()
        if args.simulator:
            available = json.loads(output("xcrun", "simctl", "list", "devices", "available", "-j"))
            devices = [d for group in available["devices"].values() for d in group]
            if not any(d["udid"] == args.simulator for d in devices):
                raise RuntimeError("Requested simulator is not available")
            simulator = args.simulator
        else:
            runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
            runtimes = [r for r in runtimes if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
            if not runtimes:
                raise RuntimeError("Install an iOS Simulator runtime in Xcode first")
            runtime = max(runtimes, key=lambda r: tuple(int(p) for p in r["version"].split(".")))
            types = json.loads(output("xcrun", "simctl", "list", "devicetypes", "-j"))["devicetypes"]
            version = [int(part) for part in runtime["version"].split(".")]
            version += [0] * (3 - len(version))
            runtime_version = (version[0] << 16) | (version[1] << 8) | version[2]
            types = [t for t in types if t.get("productFamily") == "iPhone"
                     and t.get("minRuntimeVersion", 0) <= runtime_version
                     and t.get("maxRuntimeVersion", 0xFFFFFFFF) >= runtime_version]
            if not types:
                raise RuntimeError("No compatible iPhone simulator device type")
            simulator = output("xcrun", "simctl", "create", "Precinct Regression", types[-1]["identifier"], runtime["identifier"])
            created = True
        project = ROOT / "PrecinctWeather"
        run("generate", ["xcodegen", "generate"], directory, cwd=project)
        common = ["xcodebuild", "-project", "PrecinctWeather.xcodeproj", "-destination",
                  f"platform=iOS Simulator,id={simulator}", "-derivedDataPath", str(directory / "DerivedData"),
                  "-parallel-testing-enabled", "NO"]
        class AppearanceHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path not in ("/light", "/dark"):
                    self.send_error(404)
                    return
                result = subprocess.run(["xcrun", "simctl", "ui", simulator, "appearance", self.path[1:]],
                                        capture_output=True)
                self.send_response(200 if result.returncode == 0 else 500)
                self.end_headers()
            def log_message(self, *_args):
                pass
        appearance_server = http.server.HTTPServer(("127.0.0.1", 0), AppearanceHandler)
        threading.Thread(target=appearance_server.serve_forever, daemon=True).start()
        test_env = dict(os.environ)
        test_env["TEST_RUNNER_APPEARANCE_TEST_URL"] = f"http://127.0.0.1:{appearance_server.server_port}"
        for label, scheme in [("unit", "PrecinctKitTests"), ("ui", "PrecinctWeatherUITests")]:
            run(label, common + ["-scheme", scheme, "-resultBundlePath", str(directory / f"{label}.xcresult"), "test"], directory, cwd=project, env=test_env)
            summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                                        str(directory / f"{label}.xcresult"), "--format", "json"))
            (directory / f"{label}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            if summary.get("failedTests") or summary.get("skippedTests") or not summary.get("passedTests", 0):
                raise RuntimeError(f"{label} did not execute a complete passing suite")
        run("release", ["xcodebuild", "-project", "PrecinctWeather.xcodeproj", "-scheme", "PrecinctWeather",
                        "-configuration", "Release", "-destination", "generic/platform=iOS Simulator",
                        "-derivedDataPath", str(directory / "DerivedData"), "build"], directory, cwd=project)
        bundle = directory / "DerivedData/Build/Products/Release-iphonesimulator/PrecinctWeather.app"
        embedded = bundle / "Frameworks/PrecinctKit.framework/nyc_precincts.sqlite"
        if not (bundle / "PlugIns/PrecinctWidgetExtension.appex").is_dir():
            raise RuntimeError("Release build is missing the widget extension")
        if hashlib.sha256(embedded.read_bytes()).hexdigest() != original_hash:
            raise RuntimeError("Release build does not contain the exact tested database")
        print("Full local regression suite passed. Device-only checks remain in TESTING.md.")
        return 0
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    finally:
        if appearance_server:
            appearance_server.shutdown()
            appearance_server.server_close()
        if created:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True)
        if original_hash and hashlib.sha256(database.read_bytes()).hexdigest() != original_hash:
            raise RuntimeError("Bundled database changed during verification")


if __name__ == "__main__":
    raise SystemExit(main())
