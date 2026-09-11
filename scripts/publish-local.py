#!/usr/bin/env python3
"""Package public source and checksums locally. No upload or credentials."""
import pathlib, zipfile, hashlib, json, subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
DIST=ROOT/'dist'
report=json.loads((DIST/'build-report.json').read_text())
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
        assert p.read_bytes()==subprocess.check_output(['git','show','HEAD:'+name],cwd=ROOT), 'Commit source before packaging: '+name
        z.write(p,'MarkCam/'+name)
assets=[p for p in sorted(DIST.iterdir()) if p.is_file() and p.name not in ('SHA256SUMS.txt','delivery-manifest.json')]
manifest=[{'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in assets]
(DIST/'SHA256SUMS.txt').write_text(''.join(x['sha256']+'  '+x['file']+'\n' for x in manifest))
(DIST/'delivery-manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
print(json.dumps(manifest,indent=2,ensure_ascii=False))
