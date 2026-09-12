#!/usr/bin/env python3
"""Reproducible local arm64 iOS cross-build. No account credentials required."""
import os, pathlib, plistlib, shutil, subprocess, sys, hashlib, json, struct, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
SDK=pathlib.Path(os.environ.get('IOS_SDK','/tmp/iPhoneOS16.5.sdk'))
BUILD=ROOT/'build'/'release'
APP=BUILD/'Payload'/'MarkCam.app'
DIST=ROOT/'dist'
if not SDK.is_dir(): sys.exit('Missing iOS SDK: '+str(SDK))
for tool in ('clang','ld64.lld'):
    if not shutil.which(tool): sys.exit('Missing '+tool)
resume='--resume' in sys.argv
if BUILD.exists() and not resume: shutil.rmtree(BUILD)
APP.mkdir(parents=True,exist_ok=True); DIST.mkdir(exist_ok=True)
objects=[]
for src in sorted((ROOT/'Sources').glob('*.m')):
    obj=BUILD/(src.stem+'.o')
    inputs=[src,pathlib.Path(__file__)]+list((ROOT/'Sources').glob('*.h'))
    if resume and obj.is_file() and obj.stat().st_size>0 and obj.stat().st_mtime>=max(p.stat().st_mtime for p in inputs):
        print('REUSE',src.name,flush=True);objects.append(str(obj));continue
    cmd=['clang','--target=arm64-apple-ios16.5','-isysroot',str(SDK),'-fobjc-arc','-fblocks','-fobjc-exceptions','-fexceptions','-Werror=protocol','-O2','-gline-tables-only','-Wall','-Wextra','-Wno-unused-parameter','-Wno-deprecated-declarations','-I'+str(ROOT/'Sources'),'-c',str(src),'-o',str(obj)]
    print('COMPILE',src.name,flush=True);subprocess.run(cmd,check=True);objects.append(str(obj))
frameworks=['Foundation','UIKit','AVFoundation','CoreMedia','CoreVideo','CoreImage','CoreGraphics','QuartzCore','Metal','Photos','PhotosUI','UniformTypeIdentifiers','ImageIO','MobileCoreServices']
cmd=['ld64.lld','-arch','arm64','-platform_version','ios','16.5','16.5','-syslibroot',str(SDK),'-lSystem','-lobjc','-adhoc_codesign','-dead_strip']
for f in frameworks: cmd+=['-framework',f]
cmd+=objects+['-o',str(APP/'MarkCam')];subprocess.run(cmd,check=True)
for f in (ROOT/'Resources').glob('*'):
    if f.is_file(): shutil.copy2(f,APP/f.name)
icons=['AppIcon20x2','AppIcon20x3','AppIcon29x2','AppIcon29x3','AppIcon40x2','AppIcon40x3','AppIcon60x2','AppIcon60x3']
info={
'CFBundleDevelopmentRegion':'zh_CN','CFBundleLocalizations':['zh_CN','en'],
'CFBundleExecutable':'MarkCam','CFBundleIdentifier':'app.markcam.camera','CFBundleName':'MarkCam','CFBundleDisplayName':'印记相机',
'CFBundlePackageType':'APPL','CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':'1.2.1','CFBundleVersion':'6',
'MinimumOSVersion':'16.5','UIDeviceFamily':[1],'LSRequiresIPhoneOS':True,'UIRequiredDeviceCapabilities':['arm64'],
'UILaunchScreen':{},'UIUserInterfaceStyle':'Dark','UIStatusBarStyle':'UIStatusBarStyleLightContent',
'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],
'CFBundleIcons':{'CFBundlePrimaryIcon':{'CFBundleIconFiles':icons,'UIPrerenderedIcon':False}},
'CFBundleIconFiles':icons,'UIFileSharingEnabled':True,'LSSupportsOpeningDocumentsInPlace':True,
'NSCameraUsageDescription':'用于拍照、录像和实时预览，自定义水印只在本机合成。',
'NSMicrophoneUsageDescription':'用于录制视频和 Live Photo 实况照片声音，不会后台录音或上传。',
'NSPhotoLibraryAddUsageDescription':'将拍摄的照片与视频保存到系统相册；不读取整个照片图库。',
'ITSAppUsesNonExemptEncryption':False}
with open(APP/'Info.plist','wb') as f: plistlib.dump(info,f)
privacy={'NSPrivacyTracking':False,'NSPrivacyTrackingDomains':[],'NSPrivacyCollectedDataTypes':[],'NSPrivacyAccessedAPITypes':[{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryFileTimestamp','NSPrivacyAccessedAPITypeReasons':['C617.1']}]}
with open(APP/'PrivacyInfo.xcprivacy','wb') as f: plistlib.dump(privacy,f)
os.chmod(APP/'MarkCam',0o755)
ipa=DIST/'MarkCam-1.2.1-resign-required.ipa'
with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED,compresslevel=8) as z:
    for p in sorted((BUILD/'Payload').rglob('*')):
        if p.is_file(): z.write(p,p.relative_to(BUILD))
header=struct.unpack('<IIII',open(APP/'MarkCam','rb').read(16))
assert header[0]==0xfeedfacf and header[1]==0x100000c and header[3]==2
sha=hashlib.sha256(ipa.read_bytes()).hexdigest()
source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
source_inputs=sorted(p for folder in ('Sources','Resources') for p in (ROOT/folder).rglob('*') if p.is_file())
source_digest=hashlib.sha256()
for p in source_inputs:
    source_digest.update(str(p.relative_to(ROOT)).encode()+b'\0'+p.read_bytes()+b'\0')
report={'source_commit':source_commit,'source_inputs_sha256':source_digest.hexdigest(),'compiler':subprocess.check_output(['clang','--version'],text=True).splitlines()[0],'app':'印记相机','version':'1.2.1 (6)','min_ios':'16.5','target':'arm64','sdk':'theos iPhoneOS16.5','ipa':ipa.name,'bytes':ipa.stat().st_size,'sha256':sha,'signing':'Mach-O ad-hoc signature only. Requires legitimate re-signing/provisioning to install.','device_tested':False,'source_files':[str(x.relative_to(ROOT)) for x in (ROOT/'Sources').glob('*')]}
(DIST/'build-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
(DIST/'SHA256SUMS.txt').write_text(sha+'  '+ipa.name+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
