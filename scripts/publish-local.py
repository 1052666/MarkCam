#!/usr/bin/env python3
"""Package public source and checksums locally. No upload or credentials."""
import pathlib, zipfile, hashlib, json
ROOT=pathlib.Path(__file__).resolve().parents[1]
DIST=ROOT/'dist'
report=json.loads((DIST/'build-report.json').read_text())
version=report['version'].split()[0]
ipa=DIST/report['ipa']
assert hashlib.sha256(ipa.read_bytes()).hexdigest()==report['sha256']
source=DIST/('MarkCam-'+version+'-source.zip')
folders=('Sources','Resources','scripts','docs','tests','.github')
rootfiles=('README.md','.gitignore','NOTICE.md','CHANGELOG.md','LICENSE')
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=8) as z:
    for folder in folders:
        for p in sorted((ROOT/folder).rglob('*')):
            if p.is_file() and '__pycache__' not in p.parts and p.suffix not in ('.pyc','.log','.ips'):
                z.write(p,'MarkCam/'+str(p.relative_to(ROOT)))
    for name in rootfiles:
        if (ROOT/name).is_file():z.write(ROOT/name,'MarkCam/'+name)
assets=[p for p in sorted(DIST.iterdir()) if p.is_file() and p.name not in ('SHA256SUMS.txt','delivery-manifest.json')]
manifest=[{'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in assets]
(DIST/'SHA256SUMS.txt').write_text(''.join(x['sha256']+'  '+x['file']+'\n' for x in manifest))
(DIST/'delivery-manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
print(json.dumps(manifest,indent=2,ensure_ascii=False))
