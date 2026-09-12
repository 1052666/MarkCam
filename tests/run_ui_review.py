#!/usr/bin/env python3
"""Build actual UIKit code for Simulator, exercise it, and export honest UI evidence."""
import json, os, re, pathlib, platform, plistlib, shutil, subprocess, time

ROOT=pathlib.Path(__file__).resolve().parents[1]
BUILD=ROOT/'build'/'ui-review'
OUT=ROOT/'dist'/'ui-review'
APP=BUILD/'MarkCamUIReview.app'
IDENTIFIER='app.markcam.ui-review'

def run(*args, **kwargs):
    print(' '.join(map(str,args)),flush=True)
    return subprocess.run(list(map(str,args)),check=True,**kwargs)

def output(*args):
    return subprocess.check_output(list(map(str,args)),text=True).strip()

def simjson(*args):
    return json.loads(output('xcrun','simctl',*args,'--json'))

APP.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True)
sdk=output('xcrun','--sdk','iphonesimulator','--show-sdk-path')
arch='arm64' if platform.machine()=='arm64' else 'x86_64'
sources=[p for p in sorted((ROOT/'Sources').glob('*.m')) if p.name!='main.m']+[ROOT/'tests/ui_review_main.m']
frameworks=['Foundation','UIKit','AVFoundation','CoreMedia','CoreVideo','CoreImage','CoreGraphics','QuartzCore','Metal','Photos','PhotosUI','UniformTypeIdentifiers','ImageIO','MobileCoreServices']
command=['xcrun','clang','-target',f'{arch}-apple-ios16.5-simulator','-isysroot',sdk,'-fobjc-arc','-fblocks','-fobjc-exceptions','-Werror=protocol','-Wno-deprecated-declarations','-O1','-I'+str(ROOT/'Sources'),*map(str,sources)]
for framework in frameworks:command+=['-framework',framework]
run(*command,'-o',APP/'MarkCamUIReview')
info={'CFBundleIdentifier':IDENTIFIER,'CFBundleExecutable':'MarkCamUIReview','CFBundleName':'MarkCam UI Review','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundleSupportedPlatforms':['iPhoneSimulator'],'MinimumOSVersion':'16.5','UIDeviceFamily':[1],'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'UI Review','UISceneDelegateClassName':'ReviewScene'}]}}}
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
for resource in (ROOT/'Resources').iterdir():
    if resource.is_file():shutil.copy2(resource,APP/resource.name)
run('codesign','--force','--sign','-','--timestamp=none',APP)
runtimes=[r for r in simjson('list','runtimes')['runtimes'] if r.get('isAvailable') and r['name'].startswith('iOS')]
assert runtimes,'No available iOS Simulator runtime'
major=os.environ.get('REVIEW_IOS_MAJOR','26')
runtimes=[r for r in runtimes if r['version'].split('.')[0]==major]
assert runtimes,'Required iOS '+major+' Simulator is not installed'
runtime=max(runtimes,key=lambda r:tuple(map(int,r['version'].split('.'))))
types=simjson('list','devicetypes')['devicetypes']
supported={t['identifier'] for t in runtime.get('supportedDeviceTypes',types)}
phones=[t for t in types if t['identifier'] in supported and t['name'].startswith('iPhone')]
regular=next((t for name in ['iPhone 17 Pro','iPhone 16 Pro','iPhone 16','iPhone 15'] for t in phones if t['name']==name),phones[-1])
small=next((t for t in phones if t['name']=='iPhone SE (3rd generation)'),regular)
reports=[]
for label,device in [('standard',regular),('compact',small)]:
    udid=output('xcrun','simctl','create','MarkCam-'+label,device['identifier'],runtime['identifier'])
    destination=OUT/label;destination.mkdir(exist_ok=True)
    try:
        run('xcrun','simctl','boot',udid)
        run('xcrun','simctl','bootstatus',udid,'-b',timeout=360)
        run('xcrun','simctl','status_bar',udid,'override','--time','9:41','--dataNetwork','wifi','--wifiMode','active','--wifiBars','3','--batteryState','charged','--batteryLevel','100')
        run('xcrun','simctl','install',udid,APP)
        container=pathlib.Path(output('xcrun','simctl','get_app_container',udid,IDENTIFIER,'data'))
        for launch_index in (1,2):
            launch_output=destination/('launch-'+str(launch_index));launch_output.mkdir(exist_ok=True)
            previous=container/'Documents/UIReview/ui-review-report.json'
            if previous.exists():previous.unlink()
            checkpoint=previous.parent/'checkpoint.json'
            if checkpoint.exists():checkpoint.unlink()
            run('xcrun','simctl','launch','--terminate-running-process','--stdout='+str(launch_output/'stdout.log'),'--stderr='+str(launch_output/'stderr.log'),udid,IDENTIFIER)
            container=pathlib.Path(output('xcrun','simctl','get_app_container',udid,IDENTIFIER,'data'))
            directory=container/'Documents/UIReview';report_path=directory/'ui-review-report.json'
            deadline=time.monotonic()+160
            captured=set()
            while not report_path.exists() and time.monotonic()<deadline:
                if checkpoint.exists():
                    request=json.loads(checkpoint.read_text())
                    name,token=request['name'],request['token']
                    assert re.fullmatch(r'[0-9]{2}-[a-z-]+',name) and re.fullmatch(r'[0-9A-Fa-f-]{36}',token)
                    if token not in captured:
                        time.sleep(.2) # Let the current transaction reach the compositor.
                        run('xcrun','simctl','io',udid,'screenshot',directory/(name+'.png'),timeout=30)
                        (directory/(token+'.captured')).write_text('captured')
                        captured.add(token)
                time.sleep(.1)
            if not report_path.exists():
                for log in launch_output.glob('*.log'):print(log.read_text(errors='replace'))
                raise RuntimeError('Simulator UI review did not finish')
            for path in directory.iterdir():
                if path.suffix=='.png' or path.name=='ui-review-report.json':shutil.copy2(path,launch_output/path.name)
            report=json.loads(report_path.read_text());assert report['launch_number']==launch_index, 'App data did not survive process relaunch';report['device']=device['name'];report['source_commit']=output('git','-C',ROOT,'rev-parse','HEAD')
            (launch_output/'ui-review-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
            print(json.dumps({k:v for k,v in report.items() if k not in ('checks','screenshots')},ensure_ascii=False),flush=True)
            for check in report['checks']:
                if not check['passed']:print('FAILED:',check['check'],flush=True)
            reports.append(report)
            run('xcrun','simctl','terminate',udid,IDENTIFIER)
    finally:
        subprocess.run(['xcrun','simctl','shutdown',udid],check=False)
        subprocess.run(['xcrun','simctl','delete',udid],check=False)

summary={'scope':'Actual native UIKit on two iOS Simulators; generated camera scene and event handler fixtures, no hardware capture or measured FPS','source_commit':output('git','-C',ROOT,'rev-parse','HEAD'),'passed':sum(r['passed'] for r in reports),'failed':sum(r['failed'] for r in reports),'device_tested':False,'simulator_tested':True,'process_launches':len(reports),'devices':[{'name':r['device'],'os':r['os'],'launch':r['launch_number'],'passed':r['passed'],'failed':r['failed']} for r in reports]}
(ROOT/'dist/ui-regression-report.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
assert not summary['failed'],'UIKit regression failed; inspect exported screenshots and reports'
