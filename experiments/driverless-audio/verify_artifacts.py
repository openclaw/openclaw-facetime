#!/usr/bin/env python3
"""Inspect Mach-O bytes/plists; never execute an artifact or request permission."""
import json
import os
from pathlib import Path
import plistlib
import struct
import sys


def inspect(path, platform, minimum, identifier, privacy):
    data = path.read_bytes()
    header = struct.unpack_from('<8I', data)
    assert header[0] == 0xFEEDFACF and header[1] == 0x0100000C, 'expected arm64 Mach-O'
    offset = 32
    deployment = None
    embedded = None
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', data, offset)
        assert size >= 8 and offset + size <= len(data)
        assert command != 0x1D, 'compile-only artifact must have no code signature'
        if command == 0x32:
            deployment = struct.unpack_from('<III', data, offset + 8)
        if command == 0x19:
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            for index in range(nsects):
                section = offset + 72 + 80 * index
                name = data[section:section + 16].rstrip(b'\0')
                if name == b'__info_plist':
                    length, start = struct.unpack_from('<QI', data, section + 40)
                    embedded = plistlib.loads(data[start:start + length])
        offset += size
    assert deployment and deployment[0] == platform, f'wrong platform: {deployment}'
    version = (deployment[1] >> 16, (deployment[1] >> 8) & 255, deployment[1] & 255)
    assert version == minimum, f'wrong deployment: {version}'
    assert not os.stat(path).st_mode & 0o111, 'unsigned artifact must not be executable'
    info = embedded if platform == 1 else plistlib.loads((path.parent.parent / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == identifier
    assert info['CFBundleExecutable'] == path.name
    assert info.get(privacy), 'missing privacy declaration'
    assert 'NSMicrophoneUsageDescription' not in info, 'no physical microphone recording'
    print(json.dumps({'artifact': path.name, 'architecture': 'arm64', 'platform': platform,
                      'minimum': '.'.join(map(str, version)), 'bundle_id': identifier,
                      'privacy': privacy, 'signature': 'absent', 'launchable': False}))


if __name__ == '__main__':
    root = Path(sys.argv[1])
    inspect(root / 'DriverlessInjectionProbe.app/Contents/MacOS/DriverlessInjectionProbe', 6, (18, 2, 0),
            'ai.openclaw.driverless-audio.catalyst', 'NSMicrophoneInjectionUsageDescription')
    inspect(root / 'driverless-aggregate-probe', 1, (14, 2, 0),
            'ai.openclaw.driverless-audio.aggregate', 'NSAudioCaptureUsageDescription')
