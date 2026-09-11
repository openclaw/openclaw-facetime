#!/usr/bin/env python3
"""Offline evidence bookkeeping only. No calls, capture, host probing, or consent automation."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

LANES = ('catalyst_injection', 'aggregate_input', 'paired_driver_baseline')
CALL_TYPES = ('phone_facetime_audio', 'facetime_video')
CHECKPOINTS = ('remote_audibility', 'local_playback_policy', 'physical_microphone_leakage',
               'call_mute', 'intended_call_routing', 'barge_in_stop_drain', 'call_app_restart',
               'probe_crash', 'stale_device_cleanup', 'fallback')
STATES = ('unknown', 'not_run', 'pass', 'fail', 'na')
CONSENT_SCOPES = ('endpoint', 'local_playback', 'microphone_control', 'route_changes',
                  'permission_changes', 'audio_capture', 'app_restart', 'probe_crash', 'recovery')
PLACEHOLDERS = {'unknown', 'placeholder', 'sample', 'sample evidence', 'synthetic',
                'test_only', 'dry_run', 'not_run', 'example', 'todo'}


def template():
    return {'schema_version': 1, 'evidence_kind': 'template', 'sessions': [
        {'lane': lane, 'call_type': call,
         'host': {'os_version': 'unknown', 'os_build': 'unknown', 'captured_at': 'unknown'},
         'artifact': {'identifier': 'unknown', 'sha256': 'unknown', 'signature_team': 'unknown'},
         'consent': {'state': 'unknown', 'operator': 'unknown', 'evidence_ref': 'unknown',
                     'evidence_sha256': 'unknown', 'scopes': []},
         'targeting': 'unknown',
         'checkpoints': [{'checkpoint': checkpoint, 'status': 'not_run', 'observation': '',
                          'evidence_ref': 'unknown', 'evidence_sha256': 'unknown'} for checkpoint in CHECKPOINTS]}
        for lane in LANES for call in CALL_TYPES]}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(value, names, where):
    require(isinstance(value, dict) and set(value) == set(names.split()), f'{where}: wrong fields')


def text(value, where, observed=False):
    require(isinstance(value, str) and 0 < len(value.strip()) <= 4096, f'{where}: nonempty bounded text required')
    if observed:
        require(value.strip().casefold() not in PLACEHOLDERS, f'{where}: replace the placeholder with an observation')


def digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def timestamp(value):
    text(value, 'captured_at', observed=True)
    date = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(date.tzinfo is not None and date <= datetime.now(timezone.utc), 'captured_at: real timestamp with timezone required')


def evidence(row, root, verified_files, required=True):
    ref, expected = row['evidence_ref'], row['evidence_sha256']
    if not required and (ref, expected) == ('unknown', 'unknown'):
        return
    text(ref, 'evidence_ref')
    require(digest(expected), 'evidence_sha256: SHA-256 required')
    path = Path(ref)
    require(not path.is_absolute() and '..' not in path.parts, 'evidence_ref must be a relative path within the matrix directory')
    resolved = (root / path).resolve()
    require(resolved.is_relative_to(root.resolve()), 'evidence_ref escapes matrix directory')
    # Several time-coded observations can refer to one recording or consent record.
    if resolved not in verified_files:
        require(resolved.is_file() and 0 < resolved.stat().st_size <= 64 * 1024 * 1024, 'evidence file missing, empty or over 64 MiB')
        hasher = hashlib.sha256()
        with resolved.open('rb') as stream:
            for chunk in iter(lambda: stream.read(65536), b''):
                hasher.update(chunk)
        verified_files[resolved] = hasher.hexdigest()
    require(verified_files[resolved] == expected, 'evidence content hash mismatch')


def validate(matrix, root):
    fields(matrix, 'schema_version evidence_kind sessions', 'matrix')
    require(type(matrix['schema_version']) is int and matrix['schema_version'] == 1, 'unsupported schema version')
    require(matrix['evidence_kind'] in ('template', 'live', 'test_only'), 'unknown evidence kind')
    sessions = matrix['sessions']
    require(isinstance(sessions, list) and len(sessions) <= 6, 'sessions: at most six rows')
    seen, verified_files = set(), {}
    gaps = []
    live = matrix['evidence_kind'] == 'live'
    for session in sessions:
        fields(session, 'lane call_type host artifact consent targeting checkpoints', 'session')
        lane, call = session['lane'], session['call_type']
        require(lane in LANES and call in CALL_TYPES, 'unknown lane/call type')
        key = (lane, call)
        require(key not in seen, 'duplicate session')
        seen.add(key)
        label = '/'.join(key)
        fields(session['host'], 'os_version os_build captured_at', label + '/host')
        fields(session['artifact'], 'identifier sha256 signature_team', label + '/artifact')
        consent = session['consent']
        fields(consent, 'state operator evidence_ref evidence_sha256 scopes', label + '/consent')
        require(consent['state'] in ('unknown', 'recorded'), 'unknown consent state')
        require(isinstance(consent['scopes'], list) and all(x in CONSENT_SCOPES for x in consent['scopes'])
                and len(set(consent['scopes'])) == len(consent['scopes']), 'invalid/duplicate consent scopes')
        require(session['targeting'] in ('unknown', 'observed_device_route', 'observed_untargeted_service'), 'unknown targeting enumeration')
        if session['targeting'] != 'unknown':
            expected_targeting = 'observed_untargeted_service' if lane == 'catalyst_injection' else 'observed_device_route'
            require(session['targeting'] == expected_targeting, 'targeting description contradicts lane API contract')
        for obj in (session['host'], session['artifact']):
            for name, value in obj.items():
                text(value, label + '/' + name)
        for name in ('operator', 'evidence_ref', 'evidence_sha256'):
            text(consent[name], label + '/consent/' + name)
        evidence(consent, root, verified_files, required=consent['state'] == 'recorded')
        rows = session['checkpoints']
        require(isinstance(rows, list) and len(rows) <= len(CHECKPOINTS), 'invalid checkpoints list')
        checks = set()
        observed = False
        for row in rows:
            fields(row, 'checkpoint status observation evidence_ref evidence_sha256', label + '/checkpoint')
            checkpoint, state = row['checkpoint'], row['status']
            require(checkpoint in CHECKPOINTS and checkpoint not in checks, 'invalid/duplicate checkpoint')
            checks.add(checkpoint)
            require(state in STATES, 'unknown checkpoint status')
            require(isinstance(row['observation'], str) and len(row['observation']) <= 4096, 'invalid observation')
            text(row['evidence_ref'], 'evidence_ref')
            text(row['evidence_sha256'], 'evidence_sha256')
            evidence(row, root, verified_files, required=state in ('pass', 'fail'))
            if state in ('pass', 'fail'):
                observed = True
                text(row['observation'], label + '/' + checkpoint, observed=live)
            else:
                gaps.append(label + '/' + checkpoint + ':' + state)
        gaps.extend(label + '/' + c + ':missing' for c in CHECKPOINTS if c not in checks)
        if observed:
            require(matrix['evidence_kind'] != 'template', 'template cannot contain observations')
            for name in ('os_version', 'os_build'):
                text(session['host'][name], name, observed=live)
            timestamp(session['host']['captured_at'])
            require(digest(session['artifact']['sha256']), 'captured artifact SHA-256 required')
            text(session['artifact']['identifier'], 'artifact identifier', observed=live)
            require(re.fullmatch('[A-Z0-9]{10}', session['artifact']['signature_team']) is not None, 'artifact signature team required')
            require(consent['state'] == 'recorded' and set(consent['scopes']) == set(CONSENT_SCOPES), 'recorded operator consent for all scopes required; launch flags are not evidence')
            text(consent['operator'], 'operator', observed=live)
            require(session['targeting'] != 'unknown', 'observed targeting description required')
        if session['targeting'] == 'unknown':
            gaps.append(label + '/targeting:unknown')
    for lane in LANES:
        for call in CALL_TYPES:
            if (lane, call) not in seen:
                gaps.append(lane + '/' + call + ':missing session')
    return gaps


def compare(matrix, root):
    gaps = validate(matrix, root)
    results = {}
    for candidate in LANES[:2]:
        relevant = [g for g in gaps if g.startswith(candidate + '/') or g.startswith('paired_driver_baseline/')]
        if matrix['evidence_kind'] != 'live':
            relevant.insert(0, 'evidence_kind is not live; template/test data cannot qualify')
        rows = [r for s in matrix['sessions'] if s['lane'] == candidate for r in s['checkpoints']]
        baseline = [r for s in matrix['sessions'] if s['lane'] == 'paired_driver_baseline' for r in s['checkpoints']]
        failures = [r['checkpoint'] for r in rows if r['status'] == 'fail']
        baseline_failures = [r['checkpoint'] for r in baseline if r['status'] == 'fail']
        if relevant:
            verdict = 'inconclusive'
        elif failures:
            verdict = 'cannot-replace'
        elif baseline_failures:
            verdict = 'inconclusive'
            relevant.append('paired baseline has observed failures')
        else:
            verdict = 'candidate-for-integration'
        results[candidate] = {'verdict': verdict, 'gaps': relevant, 'candidate_failures': failures,
                              'baseline_failures': baseline_failures}
    return {'candidates': results,
            'meaning': 'candidate-for-integration means passes this recorded matrix only; not production or fleet proof',
            'trust_limit': 'Checks structure and local evidence hashes, not whether an operator told the truth or a recording proves a claim.'}


def load(path):
    require(path.stat().st_size <= 1024 * 1024, 'matrix exceeds 1 MiB')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key: ' + key)
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('nonfinite JSON: ' + value)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('create', 'template', 'validate', 'compare'))
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    try:
        if args.action in ('create', 'template'):
            # Exclusive creation: never replace an existing evidence record.
            with args.path.open('x') as stream:
                json.dump(template(), stream, indent=2)
                stream.write('\n')
            result = {'created': str(args.path), 'evidence_kind': 'template'}
        else:
            matrix = load(args.path)
            result = compare(matrix, args.path.parent) if args.action == 'compare' else {
                'valid': True, 'gaps': validate(matrix, args.path.parent)}
        print(json.dumps(result, indent=2))
        return 0
    except (ValueError, OSError, TypeError, KeyError) as error:
        print(json.dumps({'valid': False, 'error': str(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
