#!/usr/bin/env python3
"""Package public source and checksums locally. No upload or credentials."""
import pathlib, zipfile, hashlib, json, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
DIST=ROOT/'dist'
report=json.loads((DIST/'build-report.json').read_text(encoding='utf-8'))
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
assert report['source_commit']==commit, 'Rebuild after changing commits'
assert not report['source_dirty'], 'Commit source before building a release'
assert subprocess.run(['git','diff','--quiet','HEAD','--'],cwd=ROOT).returncode==0, 'Commit source before packaging'
archive_time=time.gmtime(max(report['source_date_epoch'],315532800))[:6]
version=report['version'].split()[0]
ipa=DIST/report['ipa']
assert hashlib.sha256(ipa.read_bytes()).hexdigest()==report['sha256']
source=DIST/('MarkCam-'+version+'-source.zip')
tracked=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=8) as z:
    for name in sorted(n for n in tracked if n):
        p=ROOT/name
        assert p.is_file() and not p.is_symlink(),name
        assert p.suffix.lower() not in ('.log','.ips','.pem','.p12','.pfx','.key','.mobileprovision','.ipa','.zip'),name
        # Archive canonical committed bytes, including on autocrlf Windows checkouts.
        data=subprocess.check_output(['git','show','HEAD:'+name],cwd=ROOT)
        entry=zipfile.ZipInfo('MarkCam/'+name,archive_time)
        entry.create_system=3
        entry.external_attr=0o100644<<16
        z.writestr(entry,data,compress_type=zipfile.ZIP_DEFLATED,compresslevel=8)
# Publish this build and its reports, never an old IPA/source archive in dist.
assets=sorted({ipa,source,*DIST.glob('*-report.json'),*DIST.glob('*-regression.json'),*DIST.glob('*-status.json'),*DIST.glob('*-integrity.json')})
manifest=[{'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in assets]
(DIST/'SHA256SUMS.txt').write_text(''.join(x['sha256']+'  '+x['file']+'\n' for x in manifest),encoding='utf-8')
(DIST/'delivery-manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
print(json.dumps(manifest,indent=2,ensure_ascii=False))
