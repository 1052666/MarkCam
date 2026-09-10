#!/usr/bin/env python3
"""Structural/static checks only; never substitutes for real iPhone tests."""
import pathlib, zipfile, plistlib, struct, hashlib, json, io, re
from macho_inspect import MachO
from PIL import Image
ROOT=pathlib.Path(__file__).resolve().parents[1]
ipa=ROOT/'dist/MarkCam-1.1.0-resign-required.ipa'
checks=[]
def check(name,condition):
    checks.append({'check':name,'passed':bool(condition)})
    if not condition: raise AssertionError(name)
with zipfile.ZipFile(ipa) as z:
    names=z.namelist();check('ZIP integrity',z.testzip() is None)
    check('Payload root only',all(n.startswith('Payload/MarkCam.app/') for n in names))
    check('No path traversal',all(not n.startswith('/') and '..' not in pathlib.PurePosixPath(n).parts for n in names))
    check('No source/credential files in app',not any(n.endswith(('.m','.h','.json','.py','.env','.p12','.mobileprovision')) for n in names))
    root='Payload/MarkCam.app/';info=plistlib.loads(z.read(root+'Info.plist'))
    for k in ['CFBundleIdentifier','CFBundleExecutable','CFBundlePackageType','CFBundleVersion','CFBundleShortVersionString','MinimumOSVersion','UIDeviceFamily','UILaunchScreen']:
        check('Info.plist '+k,k in info)
    check('Correct executable name',info['CFBundleExecutable']=='MarkCam')
    check('Feature version 1.1.0 build 3',info['CFBundleShortVersionString']=='1.1.0' and info['CFBundleVersion']=='3')
    check('Bundle identifier unchanged',info['CFBundleIdentifier']=='app.markcam.camera')
    check('Correct minimum OS',info['MinimumOSVersion']=='16.5')
    check('iPhone device family',info['UIDeviceFamily']==[1])
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
            plat,minos,sdk,ntools=struct.unpack_from('<4I',binary,at+8);check('LC_BUILD_VERSION iOS16.5',plat==2 and minos==0x100500)
        if cmd==0x1d:signature=struct.unpack_from('<II',binary,at+8)
        at+=size
    check('Load command table size',at==32+sz)
    check('Has entry point',0x80000028 in cmds)
    check('Has system dyld',0xe in cmds)
    check('Has ad-hoc signature blob',signature is not None and sum(signature)<=len(binary))
    for framework in ['UIKit','AVFoundation','CoreImage','Photos','PhotosUI','UniformTypeIdentifiers','ImageIO']:
        check('Framework '+framework,any('/'+framework+'.framework/' in s for s in libs))
    for s in libs:check('System library only '+s,s.startswith('/System/Library/') or s.startswith('/usr/lib/'))
    parsed=MachO(binary);methods=parsed.methods('CameraViewController')
    for selector in ['captureOutput:didFinishProcessingPhoto:error:',
                     'captureOutput:didFinishCaptureForResolvedSettings:error:',
                     'captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:',
                     'captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:',
                     'captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:']:
        check('Compiled camera implements '+selector,selector in methods)
        if selector in methods:
            address=int(methods[selector],16)
            check('Method implementation in executable text '+selector,any(name=='__TEXT' and vm<=address<vm+sz for name,vm,_,off,sz in parsed.segments))
    check('No misspelled photo callback in class metadata',not any(s.startswith('photoOutput:') for s in methods))
    check('Local rejected-request diagnostic implemented','rejectPhotoRequest:' in methods and 'submitPhotoRequest' in methods)
    live_methods=parsed.methods('MCLivePhotoProcessor')
    for selector in ['processPhoto:movie:outputPhoto:outputMovie:settings:date:completion:','prepareMovie:video:settings:date:','validatePair','cancel']:
        check('Compiled live processor '+selector,selector in live_methods)
    for selector in ['openSettings','zoomSliderChanged:','setZoomFactor:','applyExposureSettings','processLiveJob:meta:']:
        check('Compiled camera feature '+selector,selector in methods)
camera=(ROOT/'Sources/CameraViewController.m').read_text();editor=(ROOT/'Sources/WMEditorViewController.m').read_text();engine=(ROOT/'Sources/WMEngine.m').read_text()
live=(ROOT/'Sources/MCLivePhotoProcessor.m').read_text()
for name,condition in [
('EV moved off main preview','exposureSlider' not in camera and 'exposureChanged:' not in camera),
('Zoom slider actual camera control','self.zoomSlider' in camera and 'd.videoZoomFactor=' in camera),
('Pinch and slider share zoom update','setZoomFactor:self.zoomStart*g.scale' in camera and 'setZoomFactor:slider.value' in camera),
('Preview gestures ignore controls','isKindOfClass:UIControl.class' in camera),
('EV persistent default','@"exposureBias":@0' in engine),
('Live persistent default off','@"livePhotoEnabled":@NO' in engine),
('EV settings route not tone','slider.tag==4' in editor and 'key:@"exposureBias"' in editor),
('Exposure clamped to device capabilities','d.minExposureTargetBias' in camera and 'd.maxExposureTargetBias' in camera),
('Native live support tested','isLivePhotoCaptureSupported' in camera and 'p.livePhotoMovieFileURL=' in camera),
('Live photo waits for both resources','self.livePhotoWritten&&self.liveMovieWritten' in camera),
('Live resource saved as pairedVideo',camera.count('PHAssetResourceTypePairedVideo')>=2),
('Live originals preserved','@"sourceMovie"' in camera and '@"outputMovie"' in camera),
('Live input pairing ID checked','kCGImagePropertyMakerAppleDictionary' in live and 'AVMetadataIdentifierQuickTimeMetadataContentIdentifier' in live),
('Live still image time preserved','com.apple.quicktime.still-image-time' in live and 'sourceFormatHint:format' in live),
('Native timed metadata track passthrough','AVMediaTypeMetadata' in live and 'outputSettings:nil' in live and 'appendSampleBuffer:sample' in live),
('Live still photo and movie both watermarked','processPhoto:image settings:settings' in live and 'overlayForSize:size settings:settings' in live),
('Live pair checked by system before save','requestLivePhotoWithResourceFileURLs:' in live and 'PHLivePhotoInfoIsDegradedKey' in live),
('Live work cancellable and bounded','120*NSEC_PER_SEC' in live and '[self.liveProcessor cancel]' in camera),
('No live networking',not any(k in live for k in ['NSURLSession','NSURLConnection','http://','https://'])),
('Photo callback required contract','@protocol MCPhotoCaptureContract' in camera and '@required' in camera),
('Exact photo selector preflight','respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)' in camera),
('No wrong photo delegate selector','void)photoOutput:' not in camera),
('Photo request exception captured with diagnostic','@catch(NSException *exception)' in camera and 'LastCaptureError.json' in camera),
('Photo output capabilities checked','availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG' in camera and 'p.highResolutionPhotoEnabled=self.photoOutput.isHighResolutionCaptureEnabled' in camera),
('Recording delegate implemented','captureOutput:(AVCaptureFileOutput *)output didFinishRecording' in camera),
('Start recording delegate implemented','captureOutput:(AVCaptureFileOutput *)output didStartRecording' in camera),
('No wrong recording delegate selector','void)fileOutput:' not in camera),
('Native high quality photo capture','capturePhotoWithSettings:p delegate:self' in camera),
('Single pending display frame','self.framePending=YES' in camera and 'self.framePending=NO' in camera),
('Fallback video preview explicitly labeled','录像兼容模式' in camera and 'nativeVideoPreview' in camera),
('Five minute recording ceiling','CMTimeMake(300,1)' in camera),
('Retry cleans partial output','无法清理上次未完成' in camera),
('Save adds original non-destructively','shouldMoveFile=NO' in camera and 'keepOriginal' in camera),
('No misparented editor header','tableHeaderView=self.header' not in editor),
('Editor canvas stays above table','self.headerHeight.constant=height' in editor),
('Editor import bounds match engine','WMEMaxBackupBytes = 32' in editor),
('Transparent assets embedded in backup','base64EncodedStringWithOptions' in engine),
('Atomic settings writes','NSDataWritingAtomic' in engine),
('Video preserves full asset and audio','initWithAsset:asset presetName:' in engine),
('No unmarked original fallback on photo render failure','return image;' not in engine),
('No app networking code',not any(k in camera+editor+engine for k in ['NSURLSession','NSURLConnection','WKWebView','GITHUB_TOKEN'])),
]:check(name,condition)
report={'scope':'IPA structure + static source assertions; NOT iOS runtime or image correctness tests','passed':sum(x['passed'] for x in checks),'failed':sum(not x['passed'] for x in checks),'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest(),'checks':checks,'device_tested':False}
(ROOT/'dist/validation-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='checks'},ensure_ascii=False,indent=2))
