#!/usr/bin/env python3
"""Execute production C policy and check Objective-C lifecycle contracts.

The source checks are static wiring checks, not execution of UIKit/PhotoKit.
"""
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
camera = (ROOT / 'Sources/CameraViewController.m').read_text().split('@implementation CameraViewController', 1)[1]
queue = (ROOT / 'Sources/MCProcessingQueue.m').read_text()


def method(text, signature):
    start = text.index(signature)
    end = text.find('\n- (', start + len(signature))
    return text[start:end if end >= 0 else len(text)]


checks = []


def check(name, condition):
    assert condition, name
    checks.append(name)


with tempfile.TemporaryDirectory() as tmp:
    executable = pathlib.Path(tmp) / 'capture-policy'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                    '-Werror', '-I' + str(ROOT / 'Sources'),
                    str(ROOT / 'tests/native_capture_probe.c'), '-o', str(executable)], check=True)
    result = subprocess.check_output([str(executable)], text=True).strip()
    print(result)

appeared = method(camera, '- (void)viewDidAppear:')
check('Editor exit holds controls until the session has restarted',
      appeared.index('self.busy=YES;[self updateControls]') < appeared.index('[self.session startRunning]'))
check('Editor exit releases worker ownership on main queue',
      'dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];});' in appeared)
check('Control updates derive capture ownership including the editor',
      'self.workQueue.captureBusy=locked||self.editorShown' in method(camera, '- (void)updateControls'))
tick = method(queue, '- (void)tick')
check('Pressure/memory recovery refreshes controls before scheduler early exits',
      tick.index('[self notify]') < tick.index('if(self.processing)') < tick.index('if(!MCCanRender'))
pressed = method(camera, '- (void)capturePressed')
check('First shutter does not get swallowed by PhotoKit authorization',
      'authorizeQueue' not in pressed and 'requestAuthorization' not in pressed and '[self startCapture]' in pressed)
save = method(queue, '- (void)save:')
check('Worker requests add-only permission and resumes its persisted job',
      'PHAuthorizationStatusNotDetermined' in save and
      'requestAuthorizationForAccessLevel:PHAccessLevelAddOnly' in save and
      'dispatch_async(dispatch_get_main_queue(),^{[self save:job meta:meta];});' in save)
check('Every capture gate uses the same mode-aware admission',
      all('[self canStartQueuedCapture]' in method(camera, signature)
          for signature in ['- (void)capturePressed', '- (void)startCapture', '- (void)queueChanged']))
check('Queue calls the tested production policy',
      'MCCanStartCapture((unsigned)self.pendingCount,live,video,self.processing,self.heavyProcessing,pressure,os_proc_available_memory())' in queue)
start = method(camera, '- (void)startCapture')
check('Recording journal is not runnable until the final callback',
      '@"kind":@"video",@"stage":@"capturing"' in start)
video_finished = method(camera, '- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecording')
check('Completed recording is made runnable only after a successful journal write',
      video_finished.index('job[@"stage"]=@"raw"') <
      video_finished.index('[self writeJob:job URL:self.activeMetaURL]') <
      video_finished.index('[self finishedCaptureJob:job'))
finished = method(camera, '- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCapture')
check('Final photo callback waits behind serial disk writes before releasing shutter',
      finished.index('dispatch_async(self.renderQueue') < finished.index('self.photoReady') <
      finished.index('[self writeJob:job URL:meta]') < finished.index('[self finishedCaptureJob:'))
check('Malformed recovery list entries are checked before keyed use',
      '[j isKindOfClass:NSDictionary.class]' in method(camera, '- (void)showFiles'))
check('Malformed individual recovery records are rejected',
      '[job isKindOfClass:NSMutableDictionary.class]' in method(camera, '- (void)showJob:'))

report = {'scope': '20 executed native C policy assertions + static Objective-C wiring checks; no iOS runtime testing',
          'native_assertions': 20, 'static_checks': checks, 'passed': 20 + len(checks),
          'failed': 0, 'device_tested': False}
(ROOT / 'dist').mkdir(exist_ok=True)
(ROOT / 'dist/capture-recovery-report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k != 'static_checks'}, indent=2))
