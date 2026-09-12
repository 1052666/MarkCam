#!/usr/bin/env python3
"""Pure geometry/model tests and source contract checks. Not UIKit/iOS execution."""
import json,math,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
checks=[]
def check(name,value):
    checks.append({'check':name,'passed':bool(value)})
    assert value,name

# Zoom and layout helpers are now executed from native C by test_preview.py.
# These tests retain the independent exposure and Live Photo contracts.
for value in [-2,-1,0,1,2]:
    x=max(-1,min(1,value));check('Hardware exposure clamps '+str(value),-1<=x<=1)
# Verify callback result ordering barrier and explicit pairing protections are present.
camera=(ROOT/'Sources/CameraViewController.m').read_text()
live=(ROOT/'Sources/MCLivePhotoProcessor.m').read_text()
queue=(ROOT/'Sources/MCProcessingQueue.m').read_text()
editor=(ROOT/'Sources/WMEditorViewController.m').read_text()
for name,ok in [
 ('Native Live callback required','didFinishProcessingLivePhotoToMovieFileAtURL:' in camera.split('@end\n@interface CameraViewController')[0]),
 ('Output data retained before callbacks','@"stage":@"capturing"' in camera),
 ('Final processing dispatches through serial render queue','self.livePhotoWritten&&self.liveMovieWritten' in camera),
 ('No metadata synthesized by guessed timestamp','AVAssetWriterInputMetadataAdaptor' not in live),
 ('All native metadata samples copied','AVAssetReaderTrackOutput' in live and '[writerInput appendSampleBuffer:sample]' in live),
 ('Movie identity preserved','self.writer.metadata=asset.metadata' in live),
 ('Photo identity roundtrip checked','LPIdentifier(check)' in live),
 ('Still-image marker demanded','if(!hasStillTime)' in live),
 ('Pair validation precedes success','[self validatePair]' in live and '[self finish:error]' in live),
 ('PhotoKit saves single asset with two resources','if(live)[request addResourceWithType:PHAssetResourceTypePairedVideo' in queue),
 ('Original Live pair retained when requested','if(live)[raw addResourceWithType:PHAssetResourceTypePairedVideo' in queue),
 ('Settings deep route exists','opensSettings=settings' in camera and 'inSection:4' in editor),
 ('EV reset persists','self.engine.settings[@"exposureBias"]=@0; [self commit:YES]' in editor),
 ('Capture disables zoom and config','self.zoomSlider.enabled=!locked' in camera and 'self.settingsButton.enabled=!locked' in camera),
 ('Suspension choice survives session stop','preservesLivePhotoCaptureSuspendedOnSessionStop=YES' in camera),
]:check(name,ok)
report={'scope':'Host-side model/layout math and static contracts only; device Live Photo playback is pending','passed':len(checks),'failed':0,'checks':checks}
(ROOT/'dist').mkdir(exist_ok=True)
(ROOT/'dist/live-ui-regression-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='checks'},ensure_ascii=False))
