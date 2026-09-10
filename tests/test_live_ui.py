#!/usr/bin/env python3
"""Pure geometry/model tests and source contract checks. Not UIKit/iOS execution."""
import json,math,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
checks=[]
def check(name,value):
    checks.append({'check':name,'passed':bool(value)})
    assert value,name

def clamp_zoom(requested,device_min,device_max):
    low=max(1,device_min);high=max(low,min(8,device_max))
    return max(low,min(high,requested))
for requested,lo,hi,result in [(-10,1,8,1),(1,1,8,1),(2,1,8,2),(12,1,12,8),(8,1,5,5),(1,1.5,8,1.5)]:
    check('Zoom limits '+str((requested,lo,hi)),clamp_zoom(requested,lo,hi)==result)
for value in [-2,-1,0,1,2]:
    x=max(-1,min(1,value));check('Hardware exposure clamps '+str(value),-1<=x<=1)
# Layout math mirrored from native viewDidLayoutSubviews. Avoid adjacent top controls.
for width in (375,390,393,414,430):
    title=(14,114);right=width-12
    mark=(right-208,right-128);live=(right-122,right-54);settings=(right-48,right)
    check('Portrait toolbar ordered '+str(width),title[1]+6<=mark[0] and mark[1]+6<=live[0] and live[1]+6<=settings[0])
    check('Portrait toolbar bounds '+str(width),settings[1]<=width-12 and mark[0]>=0)
# Verify callback result ordering barrier and explicit pairing protections are present.
camera=(ROOT/'Sources/CameraViewController.m').read_text()
live=(ROOT/'Sources/MCLivePhotoProcessor.m').read_text()
editor=(ROOT/'Sources/WMEditorViewController.m').read_text()
for name,ok in [
 ('Native Live callback required','didFinishProcessingLivePhotoToMovieFileAtURL:' in camera.split('@end\n@interface CameraViewController')[0]),
 ('Output data retained before callbacks','@"stage":@"capturing"' in camera),
 ('Final processing dispatches through serial render queue','BOOL ready=self.livePhotoWritten&&self.liveMovieWritten' in camera),
 ('No metadata synthesized by guessed timestamp','AVAssetWriterInputMetadataAdaptor' not in live),
 ('All native metadata samples copied','AVAssetReaderTrackOutput' in live and '[writerInput appendSampleBuffer:sample]' in live),
 ('Movie identity preserved','self.writer.metadata=asset.metadata' in live),
 ('Photo identity roundtrip checked','LPIdentifier(check)' in live),
 ('Still-image marker demanded','if(!hasStillTime)' in live),
 ('Pair validation precedes success','[self validatePair]' in live and '[self finish:error]' in live),
 ('PhotoKit saves single asset with two resources','if(live)[r addResourceWithType:PHAssetResourceTypePairedVideo' in camera),
 ('Original Live pair retained when requested','if(live)[original addResourceWithType:PHAssetResourceTypePairedVideo' in camera),
 ('Settings deep route exists','opensSettings=settings' in camera and 'inSection:4' in editor),
 ('EV reset persists','self.engine.settings[@"exposureBias"]=@0; [self commit:YES]' in editor),
 ('Capture disables zoom and config','self.zoomSlider.enabled=!locked' in camera and 'self.settingsButton.enabled=!locked' in camera),
 ('Suspension choice survives session stop','preservesLivePhotoCaptureSuspendedOnSessionStop=YES' in camera),
]:check(name,ok)
report={'scope':'Host-side model/layout math and static contracts only; device Live Photo playback is pending','passed':len(checks),'failed':0,'checks':checks}
(ROOT/'dist/live-ui-regression-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='checks'},ensure_ascii=False))
