#!/usr/bin/env python3
"""Build/register the local Chrome helper without changing the app or Chrome profile."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ChromeExtension'


def extension_id(manifest):
    digest = hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32]
    return ''.join(chr(ord('a') + int(char, 16)) for char in digest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage-only', action='store_true', help='Build in the workspace without installing')
    parser.add_argument('--install-root', type=Path, help='Disposable installation destination for testing')
    args = parser.parse_args()
    stage = ROOT / 'Build' / 'ChromeExtension'
    stage.mkdir(parents=True, exist_ok=True)
    binary = stage / 'research-library-chrome-host'
    # Build outside iCloud. Replacing a placeholder output can otherwise stall the linker.
    with tempfile.TemporaryDirectory(prefix='research-chrome-build-') as temporary:
        built = Path(temporary) / binary.name
        subprocess.run(['xcrun', 'swiftc', '-O', str(SOURCE / 'native-host.swift'), '-o', str(built),
                        '-module-cache-path', '/private/tmp/research-chrome-module-cache'], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(built)], check=True)
        pending = binary.with_suffix('.new')
        shutil.copy2(built, pending)
        pending.replace(binary)
    manifest = json.loads((SOURCE / 'manifest.json').read_text())
    origin = 'chrome-extension://' + extension_id(manifest) + '/'
    if args.stage_only:
        print('Built helper:', binary)
        print('Extension ID:', extension_id(manifest))
        return
    support = args.install_root or Path.home() / 'Library' / 'Application Support'
    installed = support / 'ResearchLibrary' / 'ChromeExtension'
    installed.mkdir(parents=True, exist_ok=True)
    host = installed / binary.name
    # Replace atomically so an in-flight Chrome helper can finish using its old binary.
    temporary = host.with_suffix('.new')
    shutil.copy2(binary, temporary)
    temporary.replace(host)
    browser_hosts = support / 'Google' / 'Chrome' / 'NativeMessagingHosts'
    browser_hosts.mkdir(parents=True, exist_ok=True)
    config = browser_hosts / 'org.researchlibrary.chrome.json'
    config.write_text(json.dumps({'name': 'org.researchlibrary.chrome',
        'description': 'Save PDFs to the selected Research Library Inbox',
        'path': str(host), 'type': 'stdio', 'allowed_origins': [origin]}, indent=2) + '\n')
    print('Installed local helper:', host)
    print('Chrome extension folder:', SOURCE)
    print('Extension ID:', extension_id(manifest))
    print('Load the extension once at chrome://extensions using Developer mode → Load unpacked.')


if __name__ == '__main__':
    main()
