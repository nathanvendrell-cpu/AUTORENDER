#!/usr/bin/env python3
"""Compile and run synthetic window diagnostic tests. No app/UI/PC is launched."""
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    products = ROOT / "Build/Products.noindex"
    products.mkdir(parents=True, exist_ok=True)
    inputs = [ROOT / p for p in ["Sources/RenduBar/App/StartupDiagnostic.swift", "Sources/RenduBar/App/WindowFrameDiagnostic.swift", "Scripts/WindowFrameDiagnosticTests.swift"]]
    captured = {p: p.read_bytes() for p in inputs}
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for p, data in captured.items()}
    children = []

    def run(command, timeout):
        process = subprocess.Popen([str(x) for x in command], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        children.append(process)
        try:
            output, _ = process.communicate(timeout=timeout)
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
            raise
        if process.returncode:
            raise RuntimeError(output.decode(errors="replace"))
        return output.decode()

    report = {"scope": "Synthetic local fixtures; no installed application, UI, remote host or real media", "inputs": hashes}
    try:
        with tempfile.TemporaryDirectory(prefix="public-window-diagnostic-", dir=products) as name:
            tmp = Path(name)
            copies = []
            for index, (path, data) in enumerate(captured.items()):
                target = tmp / (str(index) + "-" + path.name)
                target.write_bytes(data)
                copies.append(target)
            assert all(p.read_bytes() == data for p, data in captured.items()), "Sources changed during capture"
            compiler = ["/usr/bin/nice", "-n", "15", "/usr/bin/swiftc", "-j", "2", "-target", os.uname().machine + "-apple-macosx14.0",
                        "-parse-as-library", "-module-cache-path", tmp / "cache"]
            report["compileOutput"] = run(compiler + copies + ["-o", tmp / "tests"], 180)
            report["testOutput"] = run([tmp / "tests", tmp], 120).strip()
        report["temporaryTreeAbsent"] = not tmp.exists()
        report["status"] = "PASS_LOCAL_FIXTURES_NATIVE_UNPROVEN"
    finally:
        for child in children:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        groups = {p.pid for p in children}
        rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=,comm="], text=True)
        remaining = [row.strip() for row in rows.splitlines() if len(row.split()) >= 4 and int(row.split()[2]) in groups]
        report["remainingOwnedGroups"] = remaining
        report["processes"] = [{"pid": p.pid, "pgid": p.pid, "exit": p.returncode} for p in children]
        report["sourceDrift"] = [str(p.relative_to(ROOT)) for p, data in captured.items() if p.read_bytes() != data]
        report["intentionallyLeftRunning"] = []
        print(json.dumps(report, indent=2))
        if remaining or report["sourceDrift"]:
            raise RuntimeError("Process/source invariant failed")


if __name__ == "__main__":
    main()
