#!/usr/bin/env python3
"""Run the production capture delegate against simulated callbacks on macOS.

Linux/Windows cannot execute AVFoundation; they emit an explicit skip, never a
passing regression report. The macOS CI job is required for this integration test.
"""
import json
import os
import pathlib
import platform
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
if platform.system() != 'Darwin':
    print(json.dumps({
        'status': 'skipped',
        'reason': 'Host AVFoundation execution requires macOS; run the macOS CI job',
        'device_tested': False,
    }))
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='markcam-capture-test-') as tmp:
    exe = pathlib.Path(tmp) / 'capture-probe'
    cmd = [
        os.environ.get('CLANG', 'clang'), '-fobjc-arc', '-fblocks',
        '-Werror=protocol', '-Wno-deprecated-declarations',
        '-I' + str(ROOT / 'Sources'),
        str(ROOT / 'Sources/MCPhotoCaptureProcessor.m'),
        str(ROOT / 'tests/native_capture_probe.m'),
        '-framework', 'Foundation', '-framework', 'AVFoundation',
        '-framework', 'CoreMedia', '-o', str(exe),
    ]
    subprocess.run(cmd, check=True, timeout=120)
    result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stdout + '\n' + result.stderr
    report = json.loads(result.stdout)
    assert report['passed'] >= 50 and report['failed'] == 0, report
    report['host_platform'] = platform.platform()
    (ROOT / 'dist').mkdir(exist_ok=True)
    (ROOT / 'dist/capture-pipeline-regression-report.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
