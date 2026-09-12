#!/usr/bin/env python3
"""IPA structure and source contracts; never substitutes for iPhone tests."""
import argparse
import hashlib
import io
import json
import pathlib
import plistlib
import struct
import zipfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
PHOTO_SELECTORS=[
    'captureOutput:didCapturePhotoForResolvedSettings:',
    'captureOutput:didFinishProcessingPhoto:error:',
    'captureOutput:didFinishCaptureForResolvedSettings:error:',
    'captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:',
]
checks=[]
def check(name,condition):
    checks.append({'check':name,'passed':bool(condition)})
    if not condition:
        raise AssertionError(name)

def validate_ipa(ipa,build_report):
    from macho_inspect import MachO
    from PIL import Image
    check('IPA checksum matches build report',
          hashlib.sha256(ipa.read_bytes()).hexdigest()==build_report['sha256'])
    with zipfile.ZipFile(ipa) as z:
        names=z.namelist();check('ZIP integrity',z.testzip() is None);check('No duplicate ZIP members',len(names)==len(set(names)))
        check('Payload root only',all(n.startswith('Payload/MarkCam.app/') for n in names))
        check('No path traversal',all(not n.startswith('/') and '..' not in pathlib.PurePosixPath(n).parts for n in names))
        check('No source/credential files in app',not any(n.endswith(('.m','.h','.json','.py','.env','.p12','.mobileprovision')) for n in names))
        root='Payload/MarkCam.app/';info=plistlib.loads(z.read(root+'Info.plist'))
        for k in ['CFBundleIdentifier','CFBundleExecutable','CFBundlePackageType','CFBundleVersion','CFBundleShortVersionString','MinimumOSVersion','UIDeviceFamily','UILaunchScreen']:
            check('Info.plist '+k,k in info)
        check('Correct executable name',info['CFBundleExecutable']=='MarkCam')
        check('Bundle version matches build report',build_report['version']==info['CFBundleShortVersionString']+' ('+info['CFBundleVersion']+')')
        check('Bundle identifier unchanged',info['CFBundleIdentifier']=='app.markcam.camera')
        check('Correct minimum OS',info['MinimumOSVersion']=='16.5')
        check('iPhone device family',info['UIDeviceFamily']==[1])
        check('Native scene lifecycle declared',info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName']=='MCSceneDelegate')
        check('No Liquid Glass compatibility opt-out',not info.get('UIDesignRequiresCompatibility',False))
        for k in ['NSCameraUsageDescription','NSMicrophoneUsageDescription','NSPhotoLibraryAddUsageDescription']:
            check('Permission '+k,len(info.get(k,''))>8)
        check('No read-all photo permission','NSPhotoLibraryUsageDescription' not in info)
        check('No location permission',not any(k.startswith('NSLocation') for k in info))
        check('No arbitrary network exception','NSAppTransportSecurity' not in info)
        check('File-sharing recovery enabled',info['UIFileSharingEnabled'] and info['LSSupportsOpeningDocumentsInPlace'])
        expected={'AppIcon1024':1024,'AppIcon20x2':40,'AppIcon20x3':60,'AppIcon29x2':58,'AppIcon29x3':87,'AppIcon40x2':80,'AppIcon40x3':120,'AppIcon60x2':120,'AppIcon60x3':180}
        for name,size in expected.items():
            im=Image.open(io.BytesIO(z.read(root+name+'.png')))
            check(name+' valid opaque PNG',im.format=='PNG' and im.size==(size,size) and im.mode=='RGB')
        for n in info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconFiles']:
            check('Registered icon '+n,root+n+'.png' in names)
        for n in ['stamp-leaf.png','stamp-aperture.png']:
            im=Image.open(io.BytesIO(z.read(root+n)));check(n+' transparent RGBA',im.mode=='RGBA' and im.getchannel('A').getextrema()==(0,255))
        privacy=plistlib.loads(z.read(root+'PrivacyInfo.xcprivacy'))
        check('Privacy manifest no tracking',privacy['NSPrivacyTracking'] is False and privacy['NSPrivacyCollectedDataTypes']==[])
        binary=z.read(root+'MarkCam');magic,cpu,sub,ft,ncmd,sz,flags,res=struct.unpack_from('<8I',binary)
        check('Mach-O 64-bit arm64 executable',magic==0xfeedfacf and cpu==0x100000c and ft==2)
        check('Executable permission preserved',bool((z.getinfo(root+'MarkCam').external_attr>>16)&0o111))
        check('PIE enabled',bool(flags&0x200000))
        cmds=[];libs=[];at=32;signature=None
        for _ in range(ncmd):
            cmd,size=struct.unpack_from('<II',binary,at);check('Load command bounds '+str(at),size>=8 and at+size<=len(binary))
            cmds.append(cmd)
            if cmd in (0xc,0x80000018):
                off=struct.unpack_from('<I',binary,at+8)[0];libs.append(binary[at+off:at+size].split(b'\0')[0].decode())
            if cmd==0x32:
                plat,minos,sdk,ntools=struct.unpack_from('<4I',binary,at+8);check('LC_BUILD_VERSION iOS16.5',plat==2 and minos==0x100500);check('Linked with iOS 26+ SDK for Liquid Glass',sdk>=0x1a0000)
            if cmd==0x1d:signature=struct.unpack_from('<II',binary,at+8)
            at+=size
        check('Load command table size',at==32+sz)
        check('Has entry point',0x80000028 in cmds)
        check('Has system dyld',0xe in cmds)
        check('Has ad-hoc signature blob',signature is not None and sum(signature)<=len(binary))
        for framework in ['UIKit','AVFoundation','CoreImage','Metal','Photos','PhotosUI','UniformTypeIdentifiers','ImageIO']:
            check('Framework '+framework,any('/'+framework+'.framework/' in s for s in libs))
        for s in libs:check('System library only '+s,s.startswith('/System/Library/') or s.startswith('/usr/lib/'))
        parsed=MachO(binary);methods=parsed.methods('CameraViewController')
        capture_methods=parsed.methods('MCPhotoCaptureProcessor')
        for classname,selectors in [
            ('MCPhotoCaptureProcessor',PHOTO_SELECTORS),
            ('CameraViewController',[
                'captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:',
                'captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:']),
        ]:
            compiled=capture_methods if classname=='MCPhotoCaptureProcessor' else methods
            for selector in selectors:
                check('Compiled '+classname+' implements '+selector,selector in compiled)
                address=int(compiled[selector],16)
                check('Method implementation in executable text '+selector,
                      any(name=='__TEXT' and vm<=address<vm+filesz
                          for name,vm,_,off,filesz in parsed.segments))
        check('No misspelled photo callback in delegate metadata',
              not any(s.startswith('photoOutput:') for s in capture_methods))
        for selector in ['prepare:','rejectRequest:']:
            check('Compiled per-request capture '+selector,selector in capture_methods)
        for selector in ['submitPhotoRequest:','recordCaptureError:','finishedPhotoCapture:job:meta:error:']:
            check('Compiled capture handoff '+selector,selector in methods)
        live_methods=parsed.methods('MCLivePhotoProcessor')
        for selector in ['processPhoto:movie:outputPhoto:outputMovie:settings:date:completion:','prepareMovie:video:settings:date:','validatePair','cancel']:
            check('Compiled live processor '+selector,selector in live_methods)
        for selector in ['openSettings','zoomSliderChanged:','setZoomFactor:','applyExposureSettings','queueChanged','finishedCaptureJob:meta:error:','didReceiveMemoryWarning','writeMemoryDiagnostic:']:
            check('Compiled camera feature '+selector,selector in methods)
        processing_methods=parsed.methods('MCProcessingQueue')
        for selector in ['allowsCaptureLive:','captureBlockReasonForLive:reservedCount:','resumeAfterPhotoAuthorization','tick','retry:','pause','memoryPressure','commitPhotos:meta:']:
            check('Compiled async queue '+selector,selector in processing_methods)
        check('Compiled low-memory photo renderer class', b'MCPhotoRenderer' in binary and b'renderSource:destination:settings:date:error:' in binary)
        preview_methods=parsed.methods('MCPreviewView')
        for selector in ['submitPixelBuffer:','requestSnapshot:','reset','statistics']:
            check('Compiled GPU preview '+selector,selector in preview_methods)
        for selector in ['lensChanged:','wideReferenceForDevice:','drainZoom','updatePreviewRoute','invalidateOverlay']:
            check('Compiled lens/performance method '+selector,selector in methods)

def validate_source():
    camera=(ROOT/'Sources/CameraViewController.m').read_text(encoding='utf-8');editor=(ROOT/'Sources/WMEditorViewController.m').read_text(encoding='utf-8');engine=(ROOT/'Sources/WMEngine.m').read_text(encoding='utf-8')
    live=(ROOT/'Sources/MCLivePhotoProcessor.m').read_text(encoding='utf-8')
    preview=(ROOT/'Sources/MCPreviewView.m').read_text(encoding='utf-8')
    queue=(ROOT/'Sources/MCProcessingQueue.m').read_text(encoding='utf-8');renderer=(ROOT/'Sources/MCPhotoRenderer.m').read_text(encoding='utf-8');policy=(ROOT/'Sources/MCWorkPolicy.h').read_text(encoding='utf-8')
    capture=(ROOT/'Sources/MCPhotoCaptureProcessor.m').read_text(encoding='utf-8')
    capture_header=(ROOT/'Sources/MCPhotoCaptureProcessor.h').read_text(encoding='utf-8')
    for name,condition in [
    ('Capture pipeline uses per-request delegate','capture.onExposureFinished=' in camera and 'finishedPhotoCapture:' in camera and 'delegate:capture' in camera),
    ('Controller no longer owns export sessions','exportSession' not in camera and 'liveProcessor' not in camera),
    ('Queue is finite','MC_MAX_PENDING 6' in policy and 'pending<(live?2:MC_MAX_PENDING)' in policy),
    ('Queue serializes processing','self.processing=YES' in queue and 'MCCanRender(self.foreground,self.captureBusy,self.processing' in queue),
    ('Heavy processing blocks capture','self.heavyProcessing=live||video' in queue and 'MCCaptureAdmission(' in queue and 'if(heavy)return MCAdmissionHeavyProcessing' in policy),
    ('Photo renderer reads from file and writes file','imageWithContentsOfURL:source' in renderer and 'writeJPEGRepresentationOfImage:output toURL:partial' in renderer),
    ('Photo renderer avoids full UIImage output','processPhoto:' not in renderer and 'UIImagePNGRepresentation' not in renderer),
    ('Photo renderer checks available memory','os_proc_available_memory()' in renderer and '可用内存不足' in renderer),
    ('Overlay canvas capped for memory','2048./MAX(size.width,size.height)' in renderer),
    ('Photo partial output is atomic','partial.jpg' in renderer and 'moveItemAtURL:partial toURL:destination' in renderer),
    ('Memory pressure pauses queue','DISPATCH_MEMORYPRESSURE_WARN' in queue and 'memoryPressure' in camera),
    ('Memory diagnostic local only','LastMemoryStatus.json' in camera and 'Local app metrics only' in camera),
    ('Short background leases only','beginBackgroundTaskWithName:@"Finish pending media write"' in queue and 'beginBackgroundTaskWithName:@"Save capture to disk"' in camera),
    ('Saving stage avoids silent duplicate retry','@"stage"]=@"saving"' in queue and '上次相册保存结果待确认' in camera),
    ('Ultra-wide virtual device discovery','AVCaptureDeviceTypeBuiltInTripleCamera' in camera and 'AVCaptureDeviceTypeBuiltInDualWideCamera' in camera),
    ('True lens switch factor mapping','virtualDeviceSwitchOverVideoZoomFactors' in camera and 'MCZoomHardware' in camera),
    ('Frame throttle removed','1./20' not in camera and 'lastFrameAt' not in camera),
    ('Bounded GPU work','dispatch_semaphore_create(2)' in preview and 'DISPATCH_TIME_NOW' in preview),
    ('GPU destination output','startTaskToRender:frame toDestination:destination' in preview and 'destination.flipped=YES' in preview),
    ('System preview available for neutral tone','self.nativePreview.hidden=NO' in camera and 'toneIsActive' in camera),
    ('Watermark cache off main','dispatch_async(self.overlayQueue' in camera and '[key isEqual:self.overlayKey]' in camera),
    ('Only capture settings change hardware configuration','if(liveChanged||connectionsChanged)' in camera),
    ('Snapshot on demand','requestSnapshot:' in camera and 'lastRawFrame' not in camera),
    ('Native shared geometry','MCCameraLayout a=MCLayout(' in camera),
    ('GPU stops before background','UIApplicationWillResignActiveNotification' in camera and '!self.applicationInactive' in camera),
    ('EV moved off main preview','exposureSlider' not in camera and 'exposureChanged:' not in camera),
    ('Zoom slider actual camera control','self.zoomSlider' in camera and 'd.videoZoomFactor=' in camera),
    ('Pinch and slider share zoom update','setZoomFactor:self.zoomStart*g.scale' in camera and 'setZoomFactor:slider.value' in camera),
    ('Preview gestures ignore controls','isKindOfClass:UIControl.class' in camera),
    ('EV persistent default','@"exposureBias":@0' in engine),
    ('Live persistent default off','@"livePhotoEnabled":@NO' in engine),
    ('EV settings route not tone','slider.tag==4' in editor and 'key:@"exposureBias"' in editor),
    ('Exposure clamped to device capabilities','d.minExposureTargetBias' in camera and 'd.maxExposureTargetBias' in camera),
    ('Native live support tested','isLivePhotoCaptureSupported' in camera and 'p.livePhotoMovieFileURL=' in camera),
    ('Live photo waits for both resources','self.photoWritten&&(!self.live||self.movieWritten)&&!error' in capture and 'dispatch_async(self.diskQueue' in capture),
    ('Live resource saved as pairedVideo',queue.count('PHAssetResourceTypePairedVideo')==2),
    ('Live originals preserved','@"sourceMovie"' in capture and '@"outputMovie"' in capture and 'key:@"sourceMovie"' in queue),
    ('Live input pairing ID checked','kCGImagePropertyMakerAppleDictionary' in live and 'AVMetadataIdentifierQuickTimeMetadataContentIdentifier' in live),
    ('Live still image time preserved','com.apple.quicktime.still-image-time' in live and 'sourceFormatHint:format' in live),
    ('Native timed metadata track passthrough','AVMediaTypeMetadata' in live and 'outputSettings:nil' in live and 'appendSampleBuffer:sample' in live),
    ('Live still photo and movie both watermarked','MCPhotoRenderer renderSource:photo destination:self.outputPhoto' in live and 'overlayForSize:size settings:settings' in live),
    ('Live pair checked by system before save','requestLivePhotoWithResourceFileURLs:' in live and 'PHLivePhotoInfoIsDegradedKey' in live),
    ('Live work cancellable and bounded','120*NSEC_PER_SEC' in live and '[self.live cancel]' in queue and '[self.workQueue pause]' in camera),
    ('No live networking',not any(k in live for k in ['NSURLSession','NSURLConnection','http://','https://'])),
    ('Photo callback required contract','@protocol MCPhotoCaptureContract' in capture_header and '@required' in capture_header and '<MCPhotoCaptureContract>' in capture_header),
    ('All four delegate callbacks implemented',all(selector.split(':')[1]+':' in capture for selector in PHOTO_SELECTORS)),
    ('No wrong photo delegate selector','void)photoOutput:' not in capture+camera),
    ('Photo request exception captured with diagnostic','@catch(NSException *exception)' in camera and 'LastCaptureError.json' in camera),
    ('Photo output capabilities checked','availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG' in camera and 'p.maxPhotoDimensions=dimensions' in camera and 'self.photoOutput.maxPhotoQualityPrioritization' in camera),
    ('Recording delegate implemented','captureOutput:(AVCaptureFileOutput *)output didFinishRecording' in camera),
    ('Start recording delegate implemented','captureOutput:(AVCaptureFileOutput *)output didStartRecording' in camera),
    ('No wrong recording delegate selector','void)fileOutput:' not in camera),
    ('Native full-resolution photo capture','capturePhotoWithSettings:p delegate:capture' in camera and 'p.maxPhotoDimensions=dimensions' in camera),
    ('No stale UI frame backlog','self.previewGeometryPending=YES' in camera and 'self.previewGeometryPending=NO' in camera),
    ('Fallback video preview explicitly labeled','录像兼容模式' in camera and 'nativeVideoPreview' in camera),
    ('Five minute recording ceiling','CMTimeMake(300,1)' in camera),
    ('Retry cleans partial output','removeItemAtURL:url error:&e' in queue and 'removeItemAtURL:partial' in renderer),
    ('Save adds original non-destructively','shouldMoveFile=NO' in queue and 'keepOriginal' in queue),
    ('No misparented editor header','tableHeaderView=self.header' not in editor),
    ('Editor canvas stays above table','self.headerHeight.constant=height' in editor),
    ('Editor import bounds match engine','WMEMaxBackupBytes = 32' in editor),
    ('Transparent assets embedded in backup','base64EncodedStringWithOptions' in engine),
    ('Atomic settings writes','NSDataWritingAtomic' in engine),
    ('Video preserves full asset and audio','initWithAsset:asset presetName:' in engine),
    ('No unmarked original fallback on photo render failure','return image;' not in engine),
    ('No app networking code',not any(k in camera+editor+engine+capture+queue+renderer+live for k in ['NSURLSession','NSURLConnection','WKWebView','GITHUB_TOKEN'])),
    ]:check(name,condition)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-only',action='store_true',
                        help='Check source contracts without claiming IPA validation')
    args=parser.parse_args()
    validate_source()
    ipa=None
    if not args.source_only:
        build_report=json.loads((ROOT/'dist/build-report.json').read_text(encoding='utf-8'))
        name=build_report['ipa']
        check('Build report IPA path is a filename',isinstance(name,str) and name==pathlib.Path(name).name)
        ipa=ROOT/'dist'/name
        validate_ipa(ipa,build_report)
    report={
        'scope': 'Static source assertions only; NOT binary or device validation' if args.source_only else
                 'IPA structure + static source assertions; NOT iOS runtime or image correctness tests',
        'passed':sum(x['passed'] for x in checks),
        'failed':sum(not x['passed'] for x in checks),
        'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest() if ipa else None,
        'checks':checks,
        'device_tested':False,
    }
    (ROOT/'dist').mkdir(exist_ok=True)
    filename='source-validation-report.json' if args.source_only else 'validation-report.json'
    (ROOT/'dist'/filename).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='checks'},ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
