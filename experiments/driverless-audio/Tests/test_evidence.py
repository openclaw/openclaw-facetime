"""CLI tests. All observations generated here are synthetic, temporary, TEST ONLY.

The live-shaped fixture exercises the decision branch; it is not live evidence and
is never written to the repository's evidence/ directory or shipped as a matrix.
"""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evidence

CLI = Path(evidence.__file__)


class EvidenceCLI(unittest.TestCase):
    def setUp(self):
        scratch = CLI.parent / '.build/tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='TEST-ONLY-driverless-matrix-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'matrix.json'

    def call(self, action, matrix=None):
        if matrix is not None:
            self.path.write_text(json.dumps(matrix))
        result = subprocess.run([sys.executable, str(CLI), action, str(self.path)], capture_output=True, text=True)
        return result, json.loads(result.stdout if result.returncode == 0 else result.stderr)

    def assert_inconclusive(self, matrix):
        result, data = self.call('compare', matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(row['verdict'] == 'inconclusive' for row in data['candidates'].values()))

    def fixture(self):
        """Artificial live-shaped data, solely to exercise the public CLI classifier."""
        matrix = evidence.template()
        matrix['evidence_kind'] = 'live'
        counter = 0

        def reference(row):
            nonlocal counter
            counter += 1
            # Deliberately distinct bytes model separate operator record excerpts.
            data = f'Observation record {counter}: marker sequence heard; scoped action completed.\n'.encode()
            name = f'record-{counter}.txt'
            (self.root / name).write_bytes(data)
            row['evidence_ref'] = name
            row['evidence_sha256'] = hashlib.sha256(data).hexdigest()

        for session in matrix['sessions']:
            session['host'] = {'os_version': '15.6', 'os_build': '24G84', 'captured_at': '2025-08-01T12:00:00Z'}
            session['artifact'] = {'identifier': 'ai.openclaw.driverless-audio.' + session['lane'],
                                   'sha256': hashlib.sha256(session['lane'].encode()).hexdigest(),
                                   'signature_team': 'A123456789'}
            session['targeting'] = 'observed_untargeted_service' if session['lane'] == 'catalyst_injection' else 'observed_device_route'
            session['consent'].update(state='recorded', operator='Operator A', scopes=list(evidence.CONSENT_SCOPES))
            reference(session['consent'])
            for row in session['checkpoints']:
                row.update(status='pass', observation='Operator documented the required outcome and positive controls.')
                reference(row)
        return matrix

    def test_template_is_unknown_and_dry_run_inconclusive(self):
        result, _ = self.call('create')
        self.assertEqual(result.returncode, 0)
        matrix = json.loads(self.path.read_text())
        self.assertEqual(len(matrix['sessions']), 6)
        for session in matrix['sessions']:
            self.assertEqual(session['targeting'], 'unknown')
            self.assertTrue(all(r['status'] == 'not_run' for r in session['checkpoints']))
        self.assert_inconclusive(matrix)
        result, _ = self.call('template')
        self.assertNotEqual(result.returncode, 0)  # No evidence clobber.

    def test_full_matrix_exercises_both_candidate_branches(self):
        matrix = self.fixture()
        result, data = self.call('compare', matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(r['verdict'] == 'candidate-for-integration' for r in data['candidates'].values()))
        matrix['sessions'][0]['checkpoints'][0]['status'] = 'fail'
        _, data = self.call('compare', matrix)
        self.assertEqual(data['candidates']['catalyst_injection']['verdict'], 'cannot-replace')
        self.assertEqual(data['candidates']['aggregate_input']['verdict'], 'candidate-for-integration')

    def test_every_required_checkpoint_missing_unrun_or_failing(self):
        original = self.fixture()
        for checkpoint in evidence.CHECKPOINTS:
            with self.subTest(checkpoint=checkpoint):
                matrix = copy.deepcopy(original)
                row = next(r for r in matrix['sessions'][2]['checkpoints'] if r['checkpoint'] == checkpoint)
                row['status'] = 'fail'
                _, data = self.call('compare', matrix)
                self.assertEqual(data['candidates']['aggregate_input']['verdict'], 'cannot-replace')
                for state in ('not_run', 'unknown', 'na'):
                    row['status'] = state
                    _, data = self.call('compare', matrix)
                    self.assertEqual(data['candidates']['aggregate_input']['verdict'], 'inconclusive')
                matrix['sessions'][2]['checkpoints'].remove(row)
                _, data = self.call('compare', matrix)
                self.assertEqual(data['candidates']['aggregate_input']['verdict'], 'inconclusive')

    def test_missing_baseline_or_modality(self):
        original = self.fixture()
        for remove in ('paired_driver_baseline', 'facetime_video', 'phone_facetime_audio'):
            matrix = copy.deepcopy(original)
            matrix['sessions'] = [s for s in matrix['sessions'] if remove not in (s['lane'], s['call_type'])]
            self.assert_inconclusive(matrix)
        matrix = copy.deepcopy(original)
        matrix['sessions'][4]['checkpoints'][0]['status'] = 'fail'
        self.assert_inconclusive(matrix)

    def test_invalid_duplicate_and_unverifiable_evidence(self):
        original = self.fixture()
        mutations = [
            lambda m: m.update(schema_version=2),
            lambda m: m.update(schema_version=True),
            lambda m: m['sessions'].append(m['sessions'][0]),
            lambda m: m['sessions'][0].update(lane='other'),
            lambda m: m['sessions'][0].update(targeting='uuid_targeted'),
            lambda m: m['sessions'][0]['checkpoints'][0].update(status='delivered'),
            lambda m: m['sessions'][0]['checkpoints'][0].update(observation=''),
            lambda m: m['sessions'][0]['checkpoints'][0].update(observation='sample evidence'),
            lambda m: m['sessions'][0]['checkpoints'][0].update(evidence_ref='missing.txt'),
            lambda m: m['sessions'][0]['checkpoints'][0].update(evidence_ref='../outside.txt'),
            lambda m: m['sessions'][0]['checkpoints'][0].update(evidence_sha256='0' * 64),
            lambda m: m['sessions'][0]['checkpoints'][1].update(m['sessions'][0]['checkpoints'][0]),
            lambda m: m['sessions'][0]['host'].update(os_build='unknown'),
            lambda m: m['sessions'][0]['host'].update(captured_at='unknown'),
            lambda m: m['sessions'][0]['artifact'].update(sha256='unknown'),
            lambda m: m['sessions'][0]['consent'].update(state='unknown'),
            lambda m: m['sessions'][0]['consent'].update(scopes=['endpoint']),
            lambda m: m['sessions'][0]['consent'].update(evidence_ref='--allow-audio'),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                matrix = copy.deepcopy(original)
                mutate(matrix)
                result, data = self.call('compare', matrix)
                self.assertEqual(result.returncode, 2, data)
                self.assertNotIn('candidates', data)

    def test_shared_recording_accepts_distinct_observations_and_checks_each_hash(self):
        matrix = self.fixture()
        a, b = matrix['sessions'][0]['checkpoints'][:2]
        a['observation'] = 'The remote endpoint heard the synthetic speech marker at 00:05.'
        b['observation'] = 'At 00:06 the local sample was audible as well.'
        b['status'] = 'fail'
        b['evidence_ref'], b['evidence_sha256'] = a['evidence_ref'], a['evidence_sha256']
        result, data = self.call('compare', matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data['candidates']['catalyst_injection']['verdict'], 'cannot-replace')
        b['evidence_sha256'] = '0' * 64
        result, _ = self.call('validate', matrix)
        self.assertEqual(result.returncode, 2)

    def test_populated_unrun_references_are_verified(self):
        contents = b'TEST ONLY reference-integrity fixture; no call occurred.'
        (self.root / 'reference.txt').write_bytes(contents)
        digest = hashlib.sha256(contents).hexdigest()
        for target in ('not_run', 'unknown', 'na', 'consent'):
            for ref, checksum in [('missing.txt', digest), ('../outside.txt', digest),
                                  ('reference.txt', '0' * 64), ('reference.txt', digest)]:
                with self.subTest(target=target, ref=ref, checksum=checksum):
                    matrix = evidence.template()
                    if target == 'consent':
                        row = matrix['sessions'][0]['consent']
                    else:
                        row = matrix['sessions'][0]['checkpoints'][0]
                        row['status'] = target
                    row.update(evidence_ref=ref, evidence_sha256=checksum)
                    result, data = self.call('compare', matrix)
                    if ref == 'reference.txt' and checksum == digest:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertTrue(all(r['verdict'] == 'inconclusive' for r in data['candidates'].values()))
                    else:
                        self.assertEqual(result.returncode, 2, data)

    def test_explicitly_test_only_records_never_qualify(self):
        matrix = self.fixture()
        matrix['evidence_kind'] = 'test_only'
        self.assert_inconclusive(matrix)

    def test_duplicate_json_keys_and_nonfinite_json(self):
        for contents in ('{"schema_version":1,"schema_version":1}', '{"schema_version":NaN}'):
            self.path.write_text(contents)
            result, _ = self.call('validate')
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
