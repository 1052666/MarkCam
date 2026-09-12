#!/usr/bin/env python3
"""Execute native pure-C geometry/zoom helpers on Linux; never claims iOS rendering FPS."""
import argparse,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--static-only',action='store_true',help='Run source contracts without compiling native geometry')
args=parser.parse_args()
checks=[];layouts=[]
def check(n,v):
 checks.append({'check':n,'passed':bool(v)})
 assert v,n
def overlaps(a,b):return a[0]<b[0]+b[2]-.1 and b[0]<a[0]+a[2]-.1 and a[1]<b[1]+b[3]-.1 and b[1]<a[1]+a[3]-.1
devices=[('mini',375,812,50,34),('standard',390,844,47,34),('pro',393,852,59,34),('large',430,932,59,34),('SE',375,667,20,0)]
if not args.static_only:
 with tempfile.TemporaryDirectory() as d:
  exe=pathlib.Path(d)/'probe';subprocess.run([os.environ.get('CLANG','clang'),'-O2','-I'+str(ROOT/'Sources'),str(ROOT/'tests/native_layout_probe.c'),'-lm','-o',str(exe)],check=True)
  for name,width,height,top,bottom in devices:
   for land in [False,True]:
    w,h=(height,width) if land else (width,height);t,b,l,r=(0,21,top,top) if land else (top,bottom,0,0)
    for mode in ['photo','video']:
     aspect=(4/3 if mode=='photo' else 16/9) if land else (3/4 if mode=='photo' else 9/16)
     key=f'{name}-{mode}-'+('landscape' if land else 'portrait')
     a=json.loads(subprocess.check_output([str(exe),*map(str,[w,h,t,b,l,r,aspect])]))
     layouts.append({'name':key,'width':w,'height':h,'safe':[t,b,l,r],'layout':a})
     stage=a['stage'];check(key+' preserves field aspect',abs(stage[2]/stage[3]-aspect)<1e-7)
     for k in ['stage','mode','shutter','files','flip','edit','watermark','live','settings']:
      x,y,ww,hh=a[k];check(key+' bounds '+k,x>=-.01 and y>=-.01 and x+ww<=w+.01 and y+hh<=h+.01)
     for k in ['shutter','mode','files','flip','edit']:
      if mode=='photo' or land:check(key+' preview avoids '+k,not overlaps(stage,a[k]))
      else:
       for control in ['lenses','zoomLabel','zoomSlider']:
        x,y,cw,ch=a[control];check(key+' video floating '+control+' avoids '+k,not overlaps([x+stage[0],y+stage[1],cw,ch],a[k]))
     if not land and mode=='video' and name!='SE':check(key+' full width video',abs(stage[2]-width)<.01)
     check(key+' shutter separate from editor',not overlaps(a['shutter'],a['edit']))
     for k in ['hint','lenses','zoomLabel','zoomSlider']:
      x,y,ww,hh=a[k];check(key+' stage-local bounds '+k,x>=0 and y>=0 and x+ww<=stage[2]+.01 and y+hh<=stage[3]+.01)
     check(key+' zoom touch targets',not overlaps(a['lenses'],a['zoomSlider']) and not overlaps(a['zoomLabel'],a['zoomSlider']))
     if not land and mode=='photo':
      oldtop=top+58;oldh=height-bottom-oldtop-200;oldw=min(width-24,oldh*aspect)
      check(key+' larger than v1.1.0',stage[2]*stage[3]>(oldw*oldw/aspect)*1.10)
      if name!='SE':check(key+' full width',abs(stage[2]-width)<.01)
  for requested,ref,lo,hi,expected in [(.5,2,1,16,1),(1,2,1,16,2),(2,2,1,16,4),(.1,2,1,16,1),(20,2,1,30,16),(.5,1,1,8,1),(1,1,1,8,1),(2,1,1,8,2),(8,2,1,10,10),(.5,2,2,16,2)]:
   actual=float(subprocess.check_output([str(exe),*map(str,[requested,ref,lo,hi]),'zoom']))
   check('Native lens mapping '+str((requested,ref,lo,hi)),abs(actual-expected)<1e-9)
# Demonstrate old timing gate behavior as a simulation, not a phone FPS measurement.
last=-1;accepted=0
for n in range(300):
 now=n/30
 if now-last<1/20:continue
 last=now;accepted+=1
check('Old 30Hz to 20fps gate accepts only 150/300 model frames',accepted==150)
camera=(ROOT/'Sources/CameraViewController.m').read_text(encoding='utf-8');gpu=(ROOT/'Sources/MCPreviewView.m').read_text(encoding='utf-8')
callback=camera.split('- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:')[1].split('- (BOOL)toneIsActive')[0]
render=gpu.split('- (void)submitPixelBuffer:')[1].split('- (NSDictionary *)statistics')[0]
for name,ok in [
 ('No old frame throttle','1./20' not in camera),('No UIImage per camera frame','createCGImage' not in callback and 'imageWithCGImage' not in callback),
 ('GPU rendering does not read back pixels','createCGImage' not in render),('GPU submission bounded to two','dispatch_semaphore_create(2)' in gpu and 'DISPATCH_TIME_NOW' in gpu),
 ('Preview output uses native YUV','kCVPixelFormatType_420YpCbCr8BiPlanarFullRange' in camera),('No main GPU completion wait','waitUntilCompleted' not in gpu),
 ('Watermark renders off main','dispatch_async(self.overlayQueue' in camera),('Watermark cache enabled','[key isEqual:self.overlayKey]' in camera),
 ('True ultrawide virtual discovery','AVCaptureDeviceTypeBuiltInDualWideCamera' in camera and 'AVCaptureDeviceTypeBuiltInTripleCamera' in camera),
 ('Optical mapping uses device switches','virtualDeviceSwitchOverVideoZoomFactors' in camera and 'MCZoomHardware' in camera),
 ('Lens controls synchronized','lensChanged:' in camera and '[self showZoom:self.requestedZoom]' in camera),
 ('Live processor uses queued low-memory photo renderer','MCPhotoRenderer renderSource:photo destination:self.outputPhoto' in (ROOT/'Sources/MCLivePhotoProcessor.m').read_text(encoding='utf-8')),
]:check(name,ok)
(ROOT/'dist').mkdir(exist_ok=True)
report={'scope':'Static source contracts + timing model only; native geometry not run' if args.static_only else 'Host-executed native C geometry/zoom + static contracts; not camera or UIKit runtime, not measured FPS','passed':len(checks),'failed':0,'checks':checks,'device_tested':False,'native_layouts_executed':len(layouts)}
(ROOT/'dist'/('preview-source-report.json' if args.static_only else 'preview-regression-report.json')).write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
if not args.static_only:(ROOT/'tests/layout-fixtures.json').write_text(json.dumps(layouts,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k!='checks'},ensure_ascii=False))
