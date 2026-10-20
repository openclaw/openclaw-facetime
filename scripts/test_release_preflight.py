import importlib.util
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release-preflight.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleasePreflightTests(unittest.TestCase):
    def test_current_release_metadata_has_one_nonempty_dated_section(self):
        root = Path(__file__).resolve().parent.parent
        version = dict(line.split("=", 1) for line in (root / "version.env").read_text().splitlines())["VERSION"]
        self.assertTrue(release.notes_for((root / "CHANGELOG.md").read_text(), version).strip())

    def test_notes_require_unique_dated_nonempty_section(self):
        self.assertEqual(release.notes_for('## 1.2.3 - 2026-10-12\n\n- Fix\n\n## 1.2.2 - 2026-10-11\n- Old\n', '1.2.3'), '- Fix\n')
        for text in ['## 1.2.3 - Unreleased\n- Fix', '## 1.2.3 - 2026-10-12\n', '## 1.2.3 - 2026-10-12\n- Fix\n## 1.2.3 - 2026-10-12\n- Duplicate']:
            with self.assertRaises(ValueError): release.notes_for(text, '1.2.3')

    def test_pull_request_checks_cannot_satisfy_push_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = os.getcwd()
            os.chdir(directory)
            try:
                Path('CHANGELOG.md').write_text('## 1.2.3 - 2026-10-12\n- Fix\n')
                Path('version.env').write_text('VERSION=1.2.3\n')
                Path('package.json').write_text('{"name":"fixture","version":"1.2.3"}')
                def api(path):
                    if '/branches/' in path: return {'protected': True}
                    return {'workflow_runs': [{'head_sha':'a'*40,'event':'pull_request','conclusion':'success'}]}
                with patch.dict(os.environ, {'DRY_RUN':'true','VERSION':'1.2.3','GITHUB_REPOSITORY':'owner/repo','GITHUB_REF':'refs/heads/main','CI_WORKFLOWS':'ci.yml','PACKAGE_NAME':'fixture'}, clear=True), patch.object(release,'git',return_value='a'*40), patch.object(release,'api',side_effect=api):
                    with self.assertRaisesRegex(ValueError,'no green push'): release.main()
            finally: os.chdir(previous)

class RecoveryTests(unittest.TestCase):
    def run_recovery(self, fault=None):
        source, controller = 'a' * 40, 'b' * 40
        original = 'refs/tags/v1.2.3'
        recovery = 'refs/tags/release-recovery/v1.2.3/1'
        def git(*args):
            if args == ('rev-parse', 'HEAD'): return controller
            if args[0] == 'cat-file':
                return 'commit' if fault == ('lightweight', args[-1]) else 'tag'
            if args[0] == '-c':
                if fault == ('unsigned', args[-1]):
                    raise subprocess.CalledProcessError(1, ['git', 'verify-tag'])
                return ''
            if args[0] == 'rev-parse':
                refs = {original: 'c' * 40, recovery: 'd' * 40,
                        original + '^{}': source, recovery + '^{}': controller}
                if fault == 'wrong controller' and args[1] == recovery + '^{}': return 'e' * 40
                return refs[args[1]]
            if args[0] == 'merge-base':
                if (fault == 'controller outside main' and args[-1] == 'origin/main') or (fault == 'unrelated source' and args[-1] == controller):
                    raise subprocess.CalledProcessError(1, ['git', 'merge-base'])
                return ''
            if args == ('show', source + ':CHANGELOG.md'):
                return '## 1.2.3 - 2026-10-20\n\n- Frozen original notes\n'
            if args == ('show', source + ':version.env'):
                return 'VERSION=1.2.4' if fault == 'wrong version' else 'VERSION=1.2.3'
            raise AssertionError(args)
        def api(path):
            if '/branches/main' in path: return {'protected': True}
            if '/releases?' in path: return [{'tag_name': 'v1.2.3'}] if fault == 'existing release' else []
            commit = path.split('head_sha=')[1].split('&')[0]
            return {'workflow_runs': [{'head_sha': commit, 'event': 'push', 'head_branch': 'main',
                                       'conclusion': 'failure' if fault == ('missing CI', commit) else 'success'}]}
        with tempfile.TemporaryDirectory() as directory:
            previous = os.getcwd()
            os.chdir(directory)
            try:
                Path('CHANGELOG.md').write_text('## Unreleased\n- New controller notes\n')
                Path('version.env').write_text('VERSION=9.9.9\n')
                environment = {'DRY_RUN': 'false', 'VERSION': 'release-recovery/v1.2.3/1',
                               'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_REF': recovery,
                               'GITHUB_EVENT_NAME': 'push', 'CI_WORKFLOWS': 'ci.yml', 'GITHUB_OUTPUT': 'output'}
                with patch.dict(os.environ, environment, clear=True), patch.object(release, 'git', side_effect=git), patch.object(release, 'api', side_effect=api):
                    release.main()
                return Path('output').read_text(), Path('release-notes.md').read_text()
            finally:
                os.chdir(previous)

    def test_recovers_original_source_and_notes_with_frozen_tag_objects(self):
        output, notes = self.run_recovery()
        self.assertIn('sha=' + 'a' * 40 + '\n', output)
        self.assertIn('tag_object=' + 'c' * 40 + '\n', output)
        self.assertIn('recovery_tag_object=' + 'd' * 40 + '\n', output)
        self.assertIn('tag=v1.2.3\n', output)
        self.assertEqual(notes, '- Frozen original notes\n')

    def test_requires_both_signed_annotated_tags(self):
        for tag in ['refs/tags/v1.2.3', 'refs/tags/release-recovery/v1.2.3/1']:
            for kind in ['unsigned', 'lightweight']:
                with self.subTest(tag=tag, kind=kind), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    self.run_recovery((kind, tag))

    def test_requires_green_push_ci_for_source_and_controller(self):
        for commit in ['a' * 40, 'b' * 40]:
            with self.subTest(commit=commit), self.assertRaisesRegex(ValueError, 'no green push'):
                self.run_recovery(('missing CI', commit))

    def test_rejects_wrong_source_existing_releases_and_unrelated_commits(self):
        for fault in ['wrong controller', 'wrong version', 'existing release', 'controller outside main', 'unrelated source']:
            with self.subTest(fault=fault), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                self.run_recovery(fault)

if __name__ == '__main__': unittest.main()
