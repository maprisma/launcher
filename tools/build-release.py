#!/usr/bin/env python3
"""Build a Maprisma Launcher release: dist/maprisma-launcher-<version>-x86_64.tar.gz and its SHA-256
(after Maprisma's tools/build-release.py).

The Flutter app built in a clean copy (release mode), the release identity checked, and one folder
maprisma-launcher-<version>/ with:
    app/                      the bundle (maprisma-launcher, lib/, data/)
    share/applications/       com.maprisma.Launcher.desktop
    share/metainfo/           com.maprisma.Launcher.metainfo.xml
    share/icons/hicolor/scalable/apps/com.maprisma.Launcher.svg
    LICENSE
The AUR package maprisma-launcher-bin and the AppImage are made from it (packaging/).

    tools/build-release.py
"""
import hashlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.maprisma.Launcher'
BINARY = 'maprisma-launcher'


def version() -> str:
    found = re.search(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)', (ROOT / 'flutter_app/pubspec.yaml').read_text(), re.M)
    if not found:
        sys.exit('no version in flutter_app/pubspec.yaml')
    return found.group(1)


def check_identity(stage: Path, ver: str):
    cmake = (stage / 'linux/CMakeLists.txt').read_text()
    if f'set(APPLICATION_ID "{APP_ID}")' not in cmake or f'set(BINARY_NAME "{BINARY}")' not in cmake:
        sys.exit('Unexpected application id or binary name in linux/CMakeLists.txt')
    meta = (ROOT / f'packaging/share/metainfo/{APP_ID}.metainfo.xml').read_text()
    if f'<release version="{ver}"' not in meta:
        sys.exit(f'The metainfo has no <release version="{ver}">: add it before building')


def main():
    ver = version()
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-', dir=dist) as temp:
        stage = Path(temp) / 'flutter_app'
        shutil.copytree(ROOT / 'flutter_app', stage,
                        ignore=shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', '.flutter-plugins*'))
        shutil.copytree(ROOT / 'packages', stage.parent / 'packages',
                        ignore=shutil.ignore_patterns('build', '.dart_tool'))
        check_identity(stage, ver)
        command = ['flutter', '--suppress-analytics', '--no-version-check']
        subprocess.run([*command, 'pub', 'get', '--offline'], cwd=stage, check=True)
        subprocess.run([*command, 'build', 'linux', '--release', '--no-pub'], cwd=stage, check=True)
        bundle = stage / 'build/linux/x64/release/bundle'
        if not (bundle / BINARY).is_file():
            sys.exit(f'no {BINARY} in the bundle')
        top = Path(temp) / f'{BINARY}-{ver}'
        shutil.copytree(bundle, top / 'app', symlinks=True)
        share = ROOT / 'packaging/share'
        for source in sorted(share.rglob('*')):
            if source.is_file():
                target = top / 'share' / source.relative_to(share)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        shutil.copy2(ROOT / 'LICENSE', top / 'LICENSE')
        archive = dist / f'{BINARY}-{ver}-x86_64.tar.gz'

        def owned(info):          # root-owned in any package made from it, no build user's names
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            return info
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(top, arcname=top.name, filter=owned)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / f'{archive.name}.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'\n{archive}\nsha256 {digest}')


if __name__ == '__main__':
    main()
