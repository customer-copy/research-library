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
    pdf = fixture_pdf()
    message = {'action': 'savePDF', 'id': token, 'title': '../../A paper: α / β',
               'data': base64.b64encode(pdf).decode()}
    result = run(root, message)
    assert result == {'ok': True, 'status': 'saved', 'appOpened': True}, result
    files = list((root / 'Inbox').glob('*.pdf'))
    assert len(files) == 1 and files[0].read_bytes() == pdf
    assert files[0].parent == root / 'Inbox'
    print('PASS real PDF bytes arrive atomically in Inbox with a safe filename')
    assert run(root, message)['ok']
    assert len(list((root / 'Inbox').glob('*.pdf'))) == 1
    print('PASS retry preserves the existing identical Inbox PDF')
    files[0].write_bytes(b'Unrelated original file')
    assert not run(root, message)['ok']
    assert files[0].read_bytes() == b'Unrelated original file'
    print('PASS filename collision cannot overwrite unrelated bytes')
    for data in [b'<html>login</html>', b'%PDF-garbage', b'']:
        assert not run(root, {**message, 'data': base64.b64encode(data).decode()})['ok']
    for invalid in [{**message, 'id': '../escape'}, {**message, 'action': 'delete'}, {}]:
        assert not run(root, invalid)['ok']
    assert not run(root, raw=struct.pack('<I', 48 * 1024 * 1024 + 1))['ok']
    assert not run(root, raw=struct.pack('<I', 100) + b'{}')['ok']
    assert not run(root, raw=struct.pack('<I', 1) + b'{')['ok']
    print('PASS invalid PDFs, identifiers, actions, truncated messages and oversized frames are rejected')
    assert run(root, {'action': 'status', 'id': token})['inbox'] == str(root / 'Inbox')
    assert run(root, {'action': 'capture', 'id': token, 'url': 'https://example.org/article'})['status'] == 'sent'
    assert not run(root, {'action': 'capture', 'id': token, 'url': 'file:///etc/passwd'})['ok']
    print('PASS status and article fallback report distinct outcomes')
with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
    (Path(root) / 'Inbox').symlink_to(outside, target_is_directory=True)
    assert not run(root, message)['ok']
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
