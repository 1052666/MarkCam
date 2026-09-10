#!/usr/bin/env python3
"""Compile-only regression: required photo callbacks must be implemented.
The negative control intentionally restores the v1.0.0 typo in a temporary copy.
No iOS executable is run; no camera/device behavior is claimed.
"""
import pathlib,subprocess,tempfile,os,json
ROOT=pathlib.Path(__file__).resolve().parents[1]
SDK=pathlib.Path(os.environ.get('IOS_SDK','/tmp/iPhoneOS16.5.sdk'))
source=ROOT/'Sources/CameraViewController.m'
base=['clang','--target=arm64-apple-ios16.5','-isysroot',str(SDK),'-fobjc-arc','-fblocks','-fobjc-exceptions','-fexceptions','-Werror=protocol','-Wno-deprecated-declarations','-I'+str(ROOT/'Sources'),'-fsyntax-only']
positive=subprocess.run(base+[str(source)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=150)
assert positive.returncode==0,positive.stderr
text=source.read_text();marker='@implementation CameraViewController'
head,body=text.split(marker,1)
old='- (void)captureOutput:(AVCapturePhotoOutput *)output didFinish'
assert body.count(old)==2
broken=head+marker+body.replace(old,'- (void)photoOutput:(AVCapturePhotoOutput *)output didFinish')
with tempfile.TemporaryDirectory(prefix='markcam-negative-') as tmp:
    p=pathlib.Path(tmp)/'CameraViewController.m';p.write_text(broken)
    negative=subprocess.run(base+[str(p)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=150)
    assert negative.returncode!=0,'Negative control must fail'
    assert "method 'captureOutput:didFinishProcessingPhoto:error:'" in negative.stderr
    assert "method 'captureOutput:didFinishCaptureForResolvedSettings:error:'" in negative.stderr
report={'scope':'Compile-only positive/negative regression; not device testing','fixed_source_compiles':True,'old_typo_rejected_by_compiler':True,'missing_processing_callback_reported':True,'missing_completion_callback_reported':True}
(ROOT/'dist').mkdir(exist_ok=True)
(ROOT/'dist/selector-regression-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
