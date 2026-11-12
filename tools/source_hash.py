#!/usr/bin/env python3
"""Hash the inputs covered by the focused checks, excluding generated binaries."""
import hashlib
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[1]
files = {}
for directory in ('App', 'src', 'tests', 'tools', '.github/workflows'):
    for path in sorted((root / directory).rglob('*')):
        if not path.is_file() or '__pycache__' in path.parts or path.suffix in ('.pyc', '.o'):
            continue
        relative = path.relative_to(root).as_posix()
        if relative == 'App/KidsMode/bin/kidui':
            continue
        files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
encoded = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
print(json.dumps({'sha256': hashlib.sha256(encoded).hexdigest(), 'files': files}, sort_keys=True))
