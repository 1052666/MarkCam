#!/usr/bin/env python3
"""Host-executed capture capacity policy plus queue source contracts, not iOS testing."""
import argparse
import json
import os
import pathlib
import shlex
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--static-only', action='store_true', help='Explicitly skip native policy tests when no C compiler is available.')
args = parser.parse_args()
queue = (ROOT / 'Sources/MCProcessingQueue.m').read_text(encoding='utf-8')
renderer = (ROOT / 'Sources/MCPhotoRenderer.m').read_text(encoding='utf-8')
engine = (ROOT / 'Sources/WMEngine.m').read_text(encoding='utf-8')
checks = []


def check(name, result):
    checks.append({'check': name, 'passed': bool(result)})
    assert result, name


def method(name, end):
    return queue.split(name, 1)[1].split(end, 1)[0]


tick = method('- (void)tick {', '- (void)finish:')
failure = method('- (void)failed:', '- (void)rendered:')
resume = method('- (void)resumeAfterPhotoAuthorization {', '- (NSMutableDictionary *)readJob:')
save = method('- (void)save:', '- (void)commitPhotos:')
admission = method('- (NSString *)captureBlockReasonForLive:', '- (void)pause')
check('Every tick refreshes shutter before render and pressure early returns', tick.index('[self notify]') < tick.index('if(self.processing)') < tick.index('MCCanRender('))
check('Historical recovery records do not occupy the transient capture budget', 'MIN(self.queuedCount' in admission and 'QValidJob(job)&&!job[@"queueBlocked"]' in queue)
check('Controller admission passes held requests to shared capacity policy', 'MCCaptureAdmission(' in admission and 'MIN(reserved,(NSUInteger)UINT_MAX)' in admission)
check('Permission resume waits for processing or scan to finish', 'if(self.processing||self.scanning)return;' in resume and 'self.scanning=YES' in resume)
check('Permission resume only rewrites ready blocked permission jobs', 'MCShouldResumePermissionJob([job[@"stage"]isEqual:@"ready"],job[@"queueBlocked"]!=nil,permission)' in resume)
check('Permission resume does not reset saving to ready', 'job[@"stage"]=' not in resume)
check('Legacy 1.2.0 denied jobs can resume', '需要相册权限：请点待保存 → 授权并继续' in resume)
check('Denied authorization is durably distinguished from unknown save failures', 'job[@"queueBlockReason"]=@"photo-permission"' in save)
check('Only successfully persisted permission recovery unblocks in memory', 'if([self.class writeJob:job URL:meta])[resumed addObject:meta.path]' in resume)
check('Returning from system settings requests permission recovery', '[self resumeAfterPhotoAuthorization];[self refresh]' in queue)
check('Renderer reports a typed transient memory shortage', 'code:MCPhotoRendererErrorInsufficientMemory' in renderer)
transient = failure.split('if([error.domain isEqual:MCPhotoRendererErrorDomain]', 1)[1].split('job[@"queueBlocked"]', 1)[0]
check('Transient memory shortage waits and preserves automatic retry', 'error.code==MCPhotoRendererErrorInsufficientMemory' in transient and 'self.pressureUntil=CACurrentMediaTime()+15' in transient and 'block:NO];return;' in transient)
check('Successful Photos transaction is logged before deleting source files', 'logged=[self.class writeJob:job URL:meta];if(logged)[self.class cleanupJob:job meta:meta]' in queue)
check('Recovered job validates the complete settings schema before rendering or saving', 'QValidJob(job)' in tick and '[WMEngine isValidSettingsSnapshot:job[@"settings"]]' in queue and '+ (BOOL)isValidSettingsSnapshot:(id)settings { return ValidSettings(settings); }' in engine)
validator = engine.split('static BOOL ValidSettings(id s) {', 1)[1].split('static UIImage *Decode', 1)[0]
check('Recovery schema rejects nonnumeric booleans before boolValue on the main queue', '@"keepOriginal"' in validator and '![s[k] isKindOfClass:NSNumber.class]' in validator)
check('Recovery schema validates the layer array and every layer', '!ValidLayers(s[@"layers"])' in validator and '![layers isKindOfClass:NSArray.class]' in engine and 'if(![l isKindOfClass:NSDictionary.class])return NO' in engine)
copy = renderer.split('if(completeJPEG&&!needsRendering){', 1)[1].split('uint64_t free=', 1)[0]
check('No-edit JPEG keeps original bytes and installs output atomically', 'copyItemAtURL:source toURL:partial' in copy and 'moveItemAtURL:partial toURL:destination' in copy and 'return ok;' in copy)
check('No-edit path occurs before full decode and memory estimate', renderer.index('copyItemAtURL:source toURL:partial') < renderer.index('uint64_t free=') < renderer.index('CIImage *input='))
check('Missing contrast and saturation retain neutral defaults', 'tone[@"contrast"]?[tone[@"contrast"]doubleValue]:1' in renderer and 'tone[@"saturation"]?[tone[@"saturation"]doubleValue]:1' in renderer)

native = None
if not args.static_only:
    with tempfile.TemporaryDirectory(prefix='markcam-queue-policy-') as tmp:
        exe = pathlib.Path(tmp) / ('policy.exe' if os.name == 'nt' else 'policy')
        command = shlex.split(os.environ.get('CC', 'clang'))
        subprocess.run(command + ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-I' + str(ROOT / 'Sources'), str(ROOT / 'tests/test_processing_queue_policy.c'), '-o', str(exe)], check=True, timeout=60)
        native = json.loads(subprocess.check_output([str(exe)], text=True, timeout=30))

report = {'scope': 'Host C capture admission/recovery policy and Objective-C source contracts; not iOS runtime, device capture, or measured latency.',
          'native_policy_executed': native is not None,
          'native_policy': native,
          'static_contracts': checks,
          'passed': len(checks) + (native['passed'] if native else 0), 'failed': 0}
(ROOT / 'dist').mkdir(exist_ok=True)
(ROOT / 'dist/processing-queue-regression-report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
print(json.dumps({key: value for key, value in report.items() if key != 'static_contracts'}, ensure_ascii=False))
