#!/usr/bin/env python3
"""Compile the real photo delegate and reject each required callback typo.

Each negative control changes only one implementation selector in a temporary
copy. No iOS executable is run and no camera/device behavior is claimed.
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = pathlib.Path(os.environ.get('IOS_SDK', '/tmp/iPhoneOS16.5.sdk'))
CLANG = os.environ.get('CLANG', 'clang')
assert shutil.which(CLANG), 'clang is required for positive/negative compile regression'
assert SDK.is_dir(), 'iOS SDK is required: ' + str(SDK)
base = [CLANG, '--target=arm64-apple-ios16.5', '-isysroot', str(SDK),
        '-fobjc-arc', '-fblocks', '-fobjc-exceptions', '-fexceptions',
        '-Werror=protocol', '-Wno-deprecated-declarations',
        '-I' + str(ROOT / 'Sources'), '-fsyntax-only']


def compile_source(path):
    return subprocess.run(base + [str(path)], capture_output=True, text=True,
                          timeout=150)


# Check against Apple's original protocol before the app's required redeclaration
# is visible. An invented optional selector can otherwise compile in both the
# declaration and implementation while AVFoundation never calls it.
selectors = [
    'captureOutput:didCapturePhotoForResolvedSettings:',
    'captureOutput:didFinishProcessingPhoto:error:',
    'captureOutput:didFinishCaptureForResolvedSettings:error:',
    'captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:',
]
header_path = SDK / 'System/Library/Frameworks/AVFoundation.framework/Headers/AVCapturePhotoOutput.h'
header = header_path.read_text(encoding='utf-8')
header = re.sub(r'/\*.*?\*/|//[^\n]*', '', header, flags=re.S)
protocol = re.search(
    r'@protocol\s+AVCapturePhotoCaptureDelegate\s*(?:<[^>]*>)?\s*\n(.*?)@end',
    header, re.S)
assert protocol, 'Native AVCapturePhotoCaptureDelegate protocol not found in SDK'
native_selectors = set()
for declaration in re.findall(r'-\s*\([^)]*\)\s*([^;]+);', protocol.group(1), re.S):
    parts = re.findall(r'\b([A-Za-z_]\w*)\s*:', declaration)
    if parts:
        native_selectors.add(':'.join(parts) + ':')
for selector in selectors:
    assert selector in native_selectors, 'Required callback does not exist in Apple SDK: ' + selector
assert 'captureOutput:didFinishCapturingPhotoForResolvedSettings:error:' not in native_selectors


# Compile both ends of the handoff. A delegate-only positive control would miss
# a controller that still calls removed methods or passes an incompatible type.
sources = ['MCPhotoCaptureProcessor.m', 'CameraViewController.m']
for filename in sources:
    positive = compile_source(ROOT / 'Sources' / filename)
    assert positive.returncode == 0, filename + '\n' + positive.stderr

source = (ROOT / 'Sources/MCPhotoCaptureProcessor.m').read_text(encoding='utf-8')
marker = '@implementation MCPhotoCaptureProcessor'
head, body = source.split(marker, 1)

negative_controls = []
with tempfile.TemporaryDirectory(prefix='markcam-negative-') as tmp:
    path = pathlib.Path(tmp) / 'MCPhotoCaptureProcessor.m'
    for selector in selectors:
        callback = selector.split(':')[1]
        pattern = (r'(-\s*\(void\)\s*)captureOutput'
                   r'(\s*:\s*\(AVCapturePhotoOutput\s*\*\)\s*output\s+'
                   + re.escape(callback) + r'\s*:)')
        broken, count = re.subn(pattern, r'\1photoOutput\2', body)
        assert count == 1, 'Expected exactly one implementation of ' + selector
        path.write_text(head + marker + broken, encoding='utf-8')
        negative = compile_source(path)
        assert negative.returncode != 0, 'Typo must fail to compile: ' + selector
        assert "method '" + selector + "'" in negative.stderr, negative.stderr
        assert 'not implemented' in negative.stderr, negative.stderr
        negative_controls.append({'selector': selector, 'typo_rejected': True})

report = {
    'scope': 'Real delegate/controller compile + four independent negative controls; not device testing',
    'fixed_sources_compile': sources,
    'old_typo_rejected_by_compiler': True,
    'required_selectors_exist_in_apple_sdk': selectors,
    'negative_controls': negative_controls,
    'device_tested': False,
}
(ROOT / 'dist').mkdir(exist_ok=True)
(ROOT / 'dist/selector-regression-report.json').write_text(
    json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report, indent=2))
