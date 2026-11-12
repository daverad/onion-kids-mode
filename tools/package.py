#!/usr/bin/env python3
"""Package a checked ARM candidate; never deploy it or change an SD card."""
import argparse
import datetime
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=pathlib.Path, required=True)
parser.add_argument('--checks', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, default=root / 'dist')
args = parser.parse_args()
def git(*arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments], text=True).strip()
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
if git('status', '--porcelain'):
    raise SystemExit('Commit the source before packaging; dirty source is refused.')
inputs = json.loads(subprocess.check_output(['python3', str(root / 'tools/source_hash.py')]))
checks = json.loads(args.checks.read_text())
if checks.get('mode') != 'candidate' or checks.get('result') != 'passed' or checks.get('source_sha256') != inputs['sha256']:
    raise SystemExit('Candidate checks do not match this source.')
binary = args.binary.read_bytes()
if len(binary) < 52 or binary[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<H', binary, 18)[0] != 40 or not struct.unpack_from('<I', binary, 36)[0] & 0x400:
    raise SystemExit('Expected a 32-bit little-endian ARM ELF executable.')
if inputs['sha256'].encode() + b'\0' not in binary:
    raise SystemExit('Binary was not built with this checked source fingerprint.')
# DT_NEEDED names are verified by the pinned cross-build's readelf step.
for dependency in (b'libSDL', b'libSDL_ttf', b'libSDL_image', b'libSDL_mixer', b'libSDL_rotozoom', b'libkbinput.so'):
    if dependency not in binary:
        raise SystemExit(f'Missing dynamic dependency: {dependency!r}')
commit = git('rev-parse', 'HEAD')
name = f'KidsMode-daily-{commit[:10]}-UNQUALIFIED'
args.output.mkdir(parents=True, exist_ok=True)
archive = args.output / f'{name}.zip'
source_archive = args.output / f'{name}-source.tar.gz'
manifest = {
    'status': 'Unofficial candidate; actual-Miyoo qualification and backup required before family use',
    'source_commit': commit,
    'source_inputs_sha256': inputs['sha256'],
    'multi_profile_base': '2438cfb7c5a5a539598a93ea0f9c6fb96afe3b8a',
    'onion_revision': '07505ea58c7bba698d6b9220ff43946a43cac76b',
    'toolchain': 'aemiii91/miyoomini-toolchain@sha256:e5123590ad75d27f0f4c91196e3119a255cad45f3ae15243e29a8e0a2ec50132',
    'binary_sha256': sha(args.binary),
    'checks_sha256': sha(args.checks),
    'built_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with tempfile.TemporaryDirectory() as temporary:
    stage = pathlib.Path(temporary)
    app = stage / 'KidsMode'
    shutil.copytree(root / 'App/KidsMode', app)
    shutil.copy2(args.binary, app / 'bin/kidui')
    for filename in ('README.md', 'LICENSE'):
        shutil.copy2(root / filename, app / filename)
    (app / 'docs').mkdir()
    shutil.copy2(root / 'docs/daily-allowance.md', app / 'docs/daily-allowance.md')
    (app / 'BUILD.json').write_text(json.dumps(manifest, indent=2)+'\n')
    shutil.copy2(args.checks, app / 'CHECKS.json')
    for path in [app / 'bin/kidui', *app.glob('*.sh')]: path.chmod(0o755)
    entries = sorted(path for path in app.rglob('*') if path.is_file())
    if any(path.is_symlink() for path in app.rglob('*')):
        raise SystemExit('Unexpected symlink in app package.')
    (app / 'SHA256SUMS').write_text(''.join(f'{sha(path)}  {path.relative_to(app).as_posix()}\n' for path in entries))
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(app.rglob('*')):
            if path.is_file(): bundle.write(path, path.relative_to(stage).as_posix())
    with zipfile.ZipFile(archive) as bundle:
        assert bundle.testzip() is None
        for entry in bundle.infolist():
            assert entry.filename.startswith('KidsMode/') and '..' not in pathlib.PurePosixPath(entry.filename).parts
            if entry.filename.endswith('.sh') or entry.filename.endswith('/bin/kidui'):
                assert (entry.external_attr >> 16) & 0o111 == 0o111
        extracted = stage / 'extracted'; bundle.extractall(extracted)
        for line in (extracted / 'KidsMode/SHA256SUMS').read_text().splitlines():
            digest, relative = line.split('  ', 1)
            assert sha(extracted / 'KidsMode' / relative) == digest
subprocess.run(['git', '-C', str(root), 'archive', '--format=tar.gz', f'--output={source_archive}', commit], check=True)
(args.output / f'{name}.sha256').write_text(f'{sha(archive)}  {archive.name}\n{sha(source_archive)}  {source_archive.name}\n')
(args.output / f'{name}.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(archive)
