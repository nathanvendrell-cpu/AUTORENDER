#!/usr/bin/env python3
"""Compile and run synthetic local library tests. No app/UI/PC is launched."""
from pathlib import Path
import argparse
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
    parser=argparse.ArgumentParser()
    parser.add_argument("--receipt",action="store_true",help="Synthetic receipt and direct-AST tests")
    parser.add_argument("--timing",action="store_true",help="Synthetic frame timing and verified PNG previews")
    args=parser.parse_args()
    if args.timing and args.receipt:parser.error("Choose one fixture suite")
    products = ROOT / "Build/Products.noindex"
    products.mkdir(parents=True, exist_ok=True)
    inputs = sorted(p for directory in ["Domain", "Infrastructure", "Application"]
                    for p in (ROOT / "Sources/RenduBar" / directory).glob("*.swift"))
    inputs.append(ROOT / ("Tests/NativeTimingPreviewTests.swift" if args.timing else "Tests/NativeJobReceiptTests.swift" if args.receipt else "Tests/ContextLibraryTests.swift"))
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
        with tempfile.TemporaryDirectory(prefix="public-context-check-", dir=products) as name:
            tmp = Path(name)
            copies = []
            for index, (path, data) in enumerate(captured.items()):
                target = tmp / (str(index) + "-" + path.name)
                target.write_bytes(data)
                copies.append(target)
            assert all(p.read_bytes() == data for p, data in captured.items()), "Sources changed during capture"
            compiler = ["/usr/bin/nice", "-n", "15", "/usr/bin/swiftc", "-j", "2", "-target", os.uname().machine + "-apple-macosx14.0",
                        "-parse-as-library", "-module-cache-path", tmp / "cache", "-framework", "AppKit",
                        "-framework", "SwiftUI", "-framework", "ImageIO", "-lsqlite3"]
            report["compileOutput"] = run(compiler + copies + ["-o", tmp / "tests"], 180)
            helper=tmp / "native_script_contract.py"
            helper.write_bytes((ROOT / "Sources/RenduBar/Infrastructure/native_script_contract.py").read_bytes())
            report["helperSHA256"]=hashlib.sha256(helper.read_bytes()).hexdigest()
            report["testOutput"] = run([tmp / "tests", helper if args.receipt else tmp], 120).strip()
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
