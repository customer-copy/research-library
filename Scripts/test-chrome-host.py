#!/usr/bin/env python3
"""Exercise the compiled native protocol and actual writes only in disposable folders."""
import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import uuid

HOST = Path(__file__).resolve().parents[1] / 'Build/ChromeExtension/research-library-chrome-host'


def fixture_pdf():
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>',
               b'<< /Length 0 >>\nstream\n\nendstream']
    data = b'%PDF-1.4\n'
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n'
    xref = len(data)
    data += b'xref\n0 5\n0000000000 65535 f \n'
    data += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets[1:])
    return data + f'trailer\n<< /Root 1 0 R /Size 5 >>\nstartxref\n{xref}\n%%EOF\n'.encode()


def run(root, message=None, raw=None):
    if raw is None:
        payload = json.dumps(message).encode()
        raw = struct.pack('<I', len(payload)) + payload
    process = subprocess.run([str(HOST), '--test-root', str(root)], input=raw,
                             check=True, capture_output=True, timeout=20)
    reply = process.stdout
    size, = struct.unpack('<I', reply[:4])
    assert len(reply[4:]) == size, 'Native stdout must contain only one framed JSON response'
    return json.loads(reply[4:])


with tempfile.TemporaryDirectory(prefix='research-chrome-host-') as temporary:
    root = Path(temporary)
    token = str(uuid.uuid4())
    begin = {'action': 'beginCapture', 'id': token, 'url': 'https://example.org/article', 'metadata': {'title': 'A paper'}}
    for legacy in ['savePDF', 'capture', 'delete']:
        assert not run(root, {**begin, 'action': legacy})['ok']
    print('PASS legacy and unknown actions are rejected')
    for private in ['https://127.0.0.1/a', 'https://10.0.0.5/a', 'https://192.168.1.2/a', 'https://localhost/a',
                    'https://printer.local/a', 'https://[::1]/a', 'https://[::ffff:127.0.0.1]/a', 'https://0x7f.0.0.1/a',
                    'https://127.1/a', 'https://2130706433/a', 'https://[fe80::1]/a', 'https://100.64.0.1/a', 'file:///etc/passwd']:
        reply = run(root, {**begin, 'id': str(uuid.uuid4()), 'url': private})
        assert not reply['ok'], private
        reply = run(root, {**begin, 'id': str(uuid.uuid4()), 'pdfURL': private})
        assert not reply['ok'], private
    assert not list((root / 'Inbox/BrowserCaptures').glob('*.json')) if (root / 'Inbox/BrowserCaptures').exists() else True
    print('PASS local, private and obfuscated numeric hosts are rejected before anything is written')
    for invalid in [{**begin, 'id': '../escape'}, {}]:
        assert not run(root, invalid)['ok']
    assert not run(root, raw=struct.pack('<I', 48 * 1024 * 1024 + 1))['ok']
    assert not run(root, raw=struct.pack('<I', 100) + b'{}')['ok']
    assert not run(root, raw=struct.pack('<I', 1) + b'{')['ok']
    print('PASS invalid identifiers, truncated messages and oversized frames are rejected')
    status = run(root, {'action': 'status', 'id': token, 'seq': 41})
    assert status['inbox'] == str(root / 'Inbox') and status['seq'] == 41, status
    failed = run(root, {'action': 'status', 'id': '../bad', 'seq': 42})
    assert not failed['ok'] and failed['seq'] == 42, failed
    print('PASS replies echo the request sequence number, including errors')
with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
    (Path(root) / 'Inbox').symlink_to(outside, target_is_directory=True)
    assert not run(root, {'action': 'beginCapture', 'id': str(uuid.uuid4()), 'url': 'https://example.org/a', 'metadata': {}})['ok']
    assert not list(Path(outside).iterdir())
    print('PASS Inbox symlink cannot redirect a save outside the library')

# Streaming uses bounded frames and a persistent host, so large papers are not
# encoded as one native message and unfinished bytes never appear in Inbox.
import hashlib
import sys
import time

with tempfile.TemporaryDirectory(prefix='research-chrome-stream-') as temporary:
    root = Path(temporary)
    token = str(uuid.uuid4())
    metadata = {'title': 'Human lung organoid modelling of tissue-resident antiviral T cell responses',
                'journal': 'Nature', 'doi': '10.1038/s41586-026-11114-1',
                'authors': [{'name': 'Joseph K. Rathkey'}, {'name': 'Calvin J. Kuo'}]}
    before = time.perf_counter()
    added = run(root, {'action': 'beginCapture', 'id': token, 'url': 'https://www.nature.com/articles/s41586-026-11114-1',
                       'pdfURL': 'https://www.nature.com/articles/s41586-026-11114-1.pdf', 'metadata': metadata})
    assert added['ok'], added
    print(f'PASS durable metadata handoff in {(time.perf_counter()-before)*1000:.1f} ms (no publisher requests)')
    envelope = root / 'Inbox/BrowserCaptures' / f'{token}.json'
    assert json.loads(envelope.read_text())['phase'] == 'pending'
    host = subprocess.Popen([str(HOST), '--test-root', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def exchange(message):
        data = json.dumps(message).encode()
        host.stdin.write(struct.pack('<I', len(data)) + data)
        host.stdin.flush()
        header = host.stdout.read(4)
        assert len(header) == 4, 'Host disconnected during streaming'
        length, = struct.unpack('<I', header)
        result = json.loads(host.stdout.read(length))
        assert result.get('ok'), result
        return result

    exchange({'action': 'pdfStart', 'id': token})
    assert not list((root / 'Inbox').glob('*.pdf'))
    fixture = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    expected_hash = hashlib.sha256()
    size = 0
    if fixture:
        handle = fixture.open('rb')
    else:
        import io
        handle = io.BytesIO(fixture_pdf() + b'\n%' + b' ' * (88 * 1024 * 1024))
    with handle:
        while chunk := handle.read(512 * 1024):
            expected_hash.update(chunk)
            reply = exchange({'action': 'pdfChunk', 'id': token, 'offset': size, 'data': base64.b64encode(chunk).decode()})
            size += len(chunk)
            assert reply['offset'] == size
    assert not list((root / 'Inbox').glob('*.pdf'))
    reply = exchange({'action': 'pdfFinish', 'id': token})
    assert reply['status'] == 'saved' and reply['bytes'] == size
    host.stdin.close()
    assert host.wait(timeout=20) == 0
    destination = root / 'Inbox' / f'Chrome-{token}.pdf'
    assert hashlib.sha256(destination.read_bytes()).digest() == expected_hash.digest()
    assert json.loads(envelope.read_text())['phase'] == 'ready'
    assert json.loads(envelope.read_text())['metadata'] == metadata
    print(f'PASS streaming {size / 1024 / 1024:.1f} MB: exact PDF bytes, atomic visibility and retained metadata')
    late = run(root, {'action': 'captureFailed', 'id': token, 'error': 'stale timeout'})
    assert late['ok'] and late['status'] == 'saved', late
    assert json.loads(envelope.read_text())['phase'] == 'ready'
    print('PASS a late failure report cannot downgrade a saved capture')
