#!/usr/bin/env python3
"""Validate and package an explicit source allowlist, never a working directory."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parent.parent
GENERATED = {'.git', '.build', '.swiftpm', 'dist', '__pycache__'}
ROOT_FILES = {'LICENSE', 'NOTICE.md', 'README.md', 'README.zh-CN.md', 'SECURITY.md', 'Package.swift',
              '.gitignore', 'release-files.txt'}
DOCS = {'privacy.md', 'sources.md', 'requirements-and-design.md', 'release-checklist.md'}
SCRIPTS = {'build-lyric-preview.sh', 'public-source.py', 'test-public-source.py', 'check-localization.py'}

def permitted(name):
    parts = PurePosixPath(name).parts
    if not parts or name.startswith('/') or '\\' in name or any(p in {'.', '..', '.git'} for p in parts):
        return False
    if name != PurePosixPath(name).as_posix():
        return False
    if len(parts) == 1:
        return name in ROOT_FILES
    if parts[0] == 'docs':
        return len(parts) == 2 and parts[1] in DOCS
    if parts[0] == 'scripts':
        return len(parts) == 2 and parts[1] in SCRIPTS
    if parts[0] == 'LICENSES':
        return len(parts) == 2 and parts[1] == 'SpotlightLyrics-MIT.txt'
    if parts[0] == 'Localization':
        return name == 'Localization/L10n.swift' or (len(parts) == 4 and parts[1] == 'Resources'
            and parts[2] in {'en.lproj', 'zh-Hans.lproj'} and parts[3] in {'Localizable.strings', 'InfoPlist.strings'})
    if parts[0] in {'LyricFever', 'LyricPreview'}:
        return name.endswith('.swift') or name == 'LyricPreview/Info.plist'
    return len(parts) == 3 and parts[0] == 'Tests' and parts[1] in {
        'LyricFeverCoreTests', 'LyricPreviewPolicyTests', 'LyricMateLocalizationTests'} and name.endswith('.swift')

def collect(root):
    root = root.resolve(strict=True)
    names = (root / 'release-files.txt').read_text().splitlines()
    if not names or len(set(names)) != len(names) or 'release-files.txt' not in names:
        raise ValueError('Empty, duplicate or incomplete allowlist')
    data = {}
    for name in names:
        if not permitted(name):
            raise ValueError('Disallowed release entry')
        path = root / name
        parts = PurePosixPath(name).parts
        if any(root.joinpath(*parts[:index]).is_symlink() for index in range(1, len(parts) + 1)):
            raise ValueError('Symlinks are not release inputs')
        if not path.is_file():
            raise ValueError('Missing release input')
        data[name] = path.read_bytes()
    actual = set()
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if relative.parts[0] in GENERATED or '__pycache__' in relative.parts:
            continue
        if path.is_symlink():
            raise ValueError('Unexpected symlink')
        if path.is_file():
            actual.add(relative.as_posix())
    if actual != set(data):
        raise ValueError('Unlisted files exist or allowlist is incomplete')
    return data

def tree_digest(data):
    payload = ''.join(f'{hashlib.sha256(data[name]).hexdigest()}  {name}\n' for name in sorted(data))
    return hashlib.sha256(payload.encode()).hexdigest()

def archive(data, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('xb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as tar:
                for name in sorted(data):
                    info = tarfile.TarInfo('LyricMate/' + name)
                    info.size = len(data[name])
                    info.mode = 0o755 if name.endswith('.sh') else 0o644
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    tar.addfile(info, io.BytesIO(data[name]))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'archive'])
    args = parser.parse_args()
    try:
        data = collect(ROOT)
        result = {'files': len(data), 'tree_sha256': tree_digest(data)}
        if args.action == 'archive':
            target = ROOT / 'dist/LyricMate-source.tar.gz'
            archive(data, target)
            result['archive_sha256'] = hashlib.sha256(target.read_bytes()).hexdigest()
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError) as error:
        parser.exit(1, f'Release check failed: {type(error).__name__}. Review the allowlist and output files.\n')

if __name__ == '__main__':
    main()
