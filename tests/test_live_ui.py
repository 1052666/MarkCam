#!/usr/bin/env python3
"""Source contracts for Live Photo, exposure settings and capture UI ownership.

Native geometry/policy and callback behavior have separate executable tests.
These assertions do not claim UIKit execution or Live Photo playback.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
checks = []


def read(name):
    return (ROOT / 'Sources' / name).read_text(encoding='utf-8')


def check(name, value):
    checks.append({'check': name, 'passed': bool(value)})
    assert value, name


def method(text, signature):
    start = text.index(signature)
    match = re.search(r'\n[-+] \(', text[start + len(signature):])
    return text[start:start + len(signature) + match.start()] if match else text[start:]


camera = read('CameraViewController.m')
capture = read('MCPhotoCaptureProcessor.m')
capture_header = read('MCPhotoCaptureProcessor.h')
live = read('MCLivePhotoProcessor.m')
queue = read('MCProcessingQueue.m')
editor = read('WMEditorViewController.m')
engine = read('WMEngine.m')
exposure = method(camera, '- (void)applyExposureSettings')
controls = method(camera, '- (void)updateControls')
save = method(queue, '- (void)commitPhotos:')
for name, ok in [
    ('Native Live callback required',
     'didFinishProcessingLivePhotoToMovieFileAtURL:' in capture_header.split('@end')[0]
     and '@required' in capture_header),
    ('Delegate owns recovery record before native request',
     '@"stage":@"capturing"' in capture
     and camera.index('[capture prepare:&error]') < camera.index('capturePhotoWithSettings:p delegate:capture')),
    ('Final callback waits for serial resource writes',
     'self.photoWritten&&(!self.live||self.movieWritten)&&!error' in capture
     and 'dispatch_async(self.diskQueue,^{@autoreleasepool{[self complete:error?:self.resourceError];}})' in capture),
    ('No metadata synthesized by guessed timestamp', 'AVAssetWriterInputMetadataAdaptor' not in live),
    ('All native metadata samples copied',
     'AVAssetReaderTrackOutput' in live and '[writerInput appendSampleBuffer:sample]' in live),
    ('Movie identity preserved', 'self.writer.metadata=asset.metadata' in live),
    ('Photo identity roundtrip checked', 'LPIdentifier(check)' in live),
    ('Still-image marker demanded', 'if(!hasStillTime)' in live),
    ('Pair validation precedes success', '[self validatePair]' in live and '[self finish:error]' in live),
    ('PhotoKit saves single asset with two resources',
     '[request addResourceWithType:video?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto' in save
     and 'if(live)[request addResourceWithType:PHAssetResourceTypePairedVideo' in save),
    ('Original Live pair retained when requested',
     'if(keep)' in save and 'if(live)[raw addResourceWithType:PHAssetResourceTypePairedVideo' in save),
    ('Controller delegates Photos saving to queue', 'performChanges:' not in camera and 'performChanges:' in save),
    ('Settings deep route exists', 'opensSettings=settings' in camera
     and 'selectedSegmentIndex=self.opensSettings?3:0' in editor
     and 'section : selected+1' in editor),
    ('EV reset persists', 'self.engine.settings[@"exposureBias"]=@0; [self commit:YES]' in editor),
    ('EV default belongs to capture settings', '@"exposureBias":@0' in engine and 'key:@"exposureBias"' in editor),
    ('EV ignores nonnumeric or nonfinite input',
     'isKindOfClass:NSNumber.class' in exposure and 'if(!isfinite(value))value=0' in exposure),
    ('EV clamps to UI range and actual device',
     'MAX(-2,MIN(2,value))' in exposure
     and 'MAX(d.minExposureTargetBias,MIN(d.maxExposureTargetBias,value))' in exposure
     and '[d setExposureTargetBias:target completionHandler:nil]' in exposure),
    ('Outstanding photos keep zoom and configuration locked',
     'self.photoCaptures.count>0' in controls
     and 'self.zoomSlider.enabled=!locked' in controls
     and 'self.settingsButton.enabled=!locked' in controls
     and 'self.mode.enabled=!locked' in controls),
    ('Suspension choice survives session stop', 'preservesLivePhotoCaptureSuspendedOnSessionStop=YES' in camera),
    ('Live render uses bounded photo renderer',
     'MCPhotoRenderer renderSource:photo destination:self.outputPhoto' in live),
]:
    check(name, ok)

report = {
    'scope': 'Static source contracts only; device Live Photo playback and UIKit behavior are pending',
    'passed': len(checks), 'failed': 0, 'checks': checks, 'device_tested': False,
}
(ROOT / 'dist').mkdir(exist_ok=True)
(ROOT / 'dist/live-ui-regression-report.json').write_text(
    json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
print(json.dumps({k: v for k, v in report.items() if k != 'checks'}, ensure_ascii=False))
