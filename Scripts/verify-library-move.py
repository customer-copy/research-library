#!/usr/bin/env python3
"""Verify a Research Library move: local copy vs. the iCloud original.

usage: verify_move.py <icloud_library> <local_library>

Checks:
 1. Every non-hidden file in the original has a copy at the same path with the same size
    (sizes are readable even for files iCloud has released).
 2. Every copied file still hashes to the SHA-256 the move tool recorded from the original's
    bytes (.research-library-migration/verified.tsv).
 3. Every PDF referenced by a metadata file exists locally; reports any whose bytes differ
    from the hash recorded in that metadata (pre-existing differences, not copy errors).
Prints a JSON summary; exit status 0 only if 1 and 2 pass completely.
"""
import hashlib, json, os, sys

src, dst = map(os.path.abspath, sys.argv[1:3])
state = os.path.join(dst, '.research-library-migration', 'verified.tsv')

def walk(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for name in files:
            if name.startswith('.'):
                continue
            path = os.path.join(base, name)
            yield os.path.relpath(path, root), path

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()

manifest = {}
with open(state, encoding='utf-8') as f:
    for line in f:
        rel, _, digest = line.rstrip('\n').partition('\t')
        if digest:
            manifest[rel] = digest

report = {'source_files': 0, 'missing_in_copy': [], 'size_mismatch': [], 'not_in_manifest': [],
          'hash_mismatch': [], 'copied_files_hashed': 0, 'bytes_hashed': 0,
          'extra_local_files': 0, 'metadata_files': 0, 'attachments_checked': 0,
          'attachments_missing': [], 'preexisting_hash_differences': []}
for rel, path in walk(src):
    report['source_files'] += 1
    target = os.path.join(dst, rel)
    if not os.path.exists(target):
        report['missing_in_copy'].append(rel); continue
    if os.stat(path).st_size != os.stat(target).st_size:
        report['size_mismatch'].append(rel)
    if rel not in manifest:
        report['not_in_manifest'].append(rel)
source_set = {rel for rel, _ in walk(src)}
for rel, path in walk(dst):
    if rel not in source_set:
        report['extra_local_files'] += 1  # e.g. new captures or index state since the move
        continue
    digest = manifest.get(rel)
    if digest is None:
        continue
    actual = sha256(path)
    report['copied_files_hashed'] += 1
    report['bytes_hashed'] += os.stat(path).st_size
    if actual != digest:
        report['hash_mismatch'].append(rel)
meta = os.path.join(dst, 'Metadata')
for name in os.listdir(meta):
    if not name.endswith('.json') or name.startswith('.'):
        continue
    try:
        with open(os.path.join(meta, name), encoding='utf-8') as f:
            item = json.load(f).get('item', {})
    except Exception:
        continue
    report['metadata_files'] += 1
    for resource in item.get('resources', []):
        rel = resource.get('relativePath')
        if not rel:
            continue
        report['attachments_checked'] += 1
        local = os.path.join(dst, rel)
        if not os.path.exists(local):
            if os.path.exists(os.path.join(src, rel)):
                report['attachments_missing'].append(rel)
            continue
        expected = resource.get('sha256')
        if expected and manifest.get(rel) and manifest[rel] != expected:
            report['preexisting_hash_differences'].append(rel)
ok = not (report['missing_in_copy'] or report['size_mismatch'] or report['not_in_manifest']
          or report['hash_mismatch'] or report['attachments_missing'])
report['ok'] = ok
for key, value in list(report.items()):
    if isinstance(value, list) and len(value) > 25:
        report[key] = value[:25] + [f'... {len(value) - 25} more']
print(json.dumps(report, indent=2))
sys.exit(0 if ok else 1)
