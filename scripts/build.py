#!/usr/bin/env python3
"""Native Apple SDK arm64 iOS build. No account credentials required."""
import os, pathlib, plistlib, shutil, subprocess, sys, hashlib, json, struct, zipfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
VERSION='1.4.0'
BUILD_NUMBER='8'
NATIVE=sys.platform=='darwin'
SDK=pathlib.Path(os.environ.get('IOS_SDK') or (subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip() if NATIVE else '/tmp/iPhoneOS16.5.sdk'))
SDK_VERSION=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip() if NATIVE else '16.5'
if not NATIVE or int(SDK_VERSION.split('.')[0])<26: sys.exit('Release requires Xcode 26+ and the iOS 26+ SDK for native Liquid Glass.')
BUILD=ROOT/'build'/'release'
APP=BUILD/'Payload'/'MarkCam.app'
DIST=ROOT/'dist'
if not SDK.is_dir(): sys.exit('Missing iOS SDK: '+str(SDK))
SDK_VERSION=str(plistlib.loads((SDK/'SDKSettings.plist').read_bytes())['Version'])
if int(SDK_VERSION.split('.')[0])<26: sys.exit('The selected SDK must be iOS 26 or newer.')
for tool in ('clang','codesign'):
    if not shutil.which(tool): sys.exit('Missing '+tool)
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
epoch=int(os.environ.get('SOURCE_DATE_EPOCH') or subprocess.check_output(['git','show','-s','--format=%ct','HEAD'],cwd=ROOT,text=True).strip())
archive_time=time.gmtime(max(epoch,315532800))[:6]
resume='--resume' in sys.argv
if BUILD.exists() and not resume: shutil.rmtree(BUILD)
APP.mkdir(parents=True,exist_ok=True); DIST.mkdir(exist_ok=True)
objects=[]
for src in sorted((ROOT/'Sources').glob('*.m')):
    obj=BUILD/(src.stem+'.o')
    inputs=[src,pathlib.Path(__file__)]+list((ROOT/'Sources').glob('*.h'))
    if resume and obj.is_file() and obj.stat().st_size>0 and obj.stat().st_mtime>=max(p.stat().st_mtime for p in inputs):
        print('REUSE',src.name,flush=True);objects.append(str(obj));continue
    cmd=['clang','--target=arm64-apple-ios16.5','-isysroot',str(SDK),'-fobjc-arc','-fblocks','-fobjc-exceptions','-fexceptions','-Werror=protocol','-O2','-gline-tables-only','-ffile-prefix-map='+str(ROOT)+'=/src/MarkCam','-fdebug-compilation-dir=/src/MarkCam','-Wall','-Wextra','-Wno-unused-parameter','-Wno-deprecated-declarations','-I'+str(ROOT/'Sources'),'-c',str(src),'-o',str(obj)]
    print('COMPILE',src.name,flush=True);subprocess.run(cmd,check=True);objects.append(str(obj))
frameworks=['Foundation','UIKit','AVFoundation','CoreMedia','CoreVideo','CoreImage','CoreGraphics','QuartzCore','Metal','Photos','PhotosUI','UniformTypeIdentifiers','ImageIO','MobileCoreServices']
cmd=['clang','--target=arm64-apple-ios16.5','-isysroot',str(SDK),'-Wl,-dead_strip','-Wl,-no_fixup_chains']
for f in frameworks: cmd+=['-framework',f]
cmd+=objects+['-o',str(APP/'MarkCam')];subprocess.run(cmd,check=True)
for f in (ROOT/'Resources').glob('*'):
    if f.is_file(): shutil.copy2(f,APP/f.name)
icons=['AppIcon20x2','AppIcon20x3','AppIcon29x2','AppIcon29x3','AppIcon40x2','AppIcon40x3','AppIcon60x2','AppIcon60x3']
info={
'CFBundleDevelopmentRegion':'zh_CN','CFBundleLocalizations':['zh_CN','en'],
'CFBundleExecutable':'MarkCam','CFBundleIdentifier':'app.markcam.camera','CFBundleName':'MarkCam','CFBundleDisplayName':'印记相机',
'CFBundlePackageType':'APPL','CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':VERSION,'CFBundleVersion':BUILD_NUMBER,
'MinimumOSVersion':'16.5','UIDeviceFamily':[1],'LSRequiresIPhoneOS':True,'UIRequiredDeviceCapabilities':['arm64'],
'UILaunchScreen':{},'UIStatusBarStyle':'UIStatusBarStyleLightContent',
'CFBundleSupportedPlatforms':['iPhoneOS'],'DTPlatformName':'iphoneos','DTSDKName':'iphoneos'+SDK_VERSION,
'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Camera','UISceneDelegateClassName':'MCSceneDelegate'}]}},
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
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(APP)],check=True)
ipa=DIST/('MarkCam-'+VERSION+'-resign-required.ipa')
with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED,compresslevel=8) as z:
    for p in sorted((BUILD/'Payload').rglob('*')):
        if p.is_file():
            entry=zipfile.ZipInfo(p.relative_to(BUILD).as_posix(),archive_time)
            entry.create_system=3
            entry.external_attr=(0o100755 if p.name=='MarkCam' else 0o100644)<<16
            z.writestr(entry,p.read_bytes(),compress_type=zipfile.ZIP_DEFLATED,compresslevel=8)
header=struct.unpack('<IIII',open(APP/'MarkCam','rb').read(16))
assert header[0]==0xfeedfacf and header[1]==0x100000c and header[3]==2
sha=hashlib.sha256(ipa.read_bytes()).hexdigest()
report={'app':'印记相机','version':VERSION+' ('+BUILD_NUMBER+')','min_ios':'16.5','target':'arm64','sdk':'Apple iPhoneOS'+SDK_VERSION,'ipa':ipa.name,'bytes':ipa.stat().st_size,'sha256':sha,'signing':'Mach-O ad-hoc signature only. Requires legitimate re-signing/provisioning to install.','device_tested':False,'source_commit':commit,'source_date_epoch':epoch,'source_dirty':bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=ROOT,text=True).strip()),'toolchain':{tool:subprocess.check_output([tool,'--version'],text=True).splitlines()[0] for tool in ('clang',)},'source_files':[x.relative_to(ROOT).as_posix() for x in sorted((ROOT/'Sources').glob('*'))]}
(DIST/'build-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(DIST/'SHA256SUMS.txt').write_text(sha+'  '+ipa.name+'\n',encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2))
