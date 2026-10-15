#!/usr/bin/env python3
"""Public merge/journal behavior against static transport data and real Git objects."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

FIXTURES = Path(__file__).resolve().parent
ROOT = FIXTURES.parents[2]
URL = 'https://github.com/example/repo/pull/7'
HEAD = (FIXTURES / 'head.sha').read_text().strip()
ZERO_HEAD = (FIXTURES / 'head-zero.sha').read_text().strip()

class Journal(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fm-journal-')
        self.addCleanup(self.temp.cleanup)
        self.world = Path(self.temp.name)
        self.home = self.world / 'home'
        self.state = self.home / 'state'
        self.state.mkdir(parents=True)
        (self.home / 'data').mkdir()
        (self.home / 'config').mkdir()
        (self.home / 'config/backlog-backend').write_text('manual\n')
        (self.home / '.tasks.toml').write_bytes((ROOT / '.tasks.toml').read_bytes())
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        self.repo = self.world / 'repo'
        self.repo.mkdir()
        fakebin = self.world / 'fakebin'
        fakebin.mkdir()
        for name in ('gh', 'gh-axi', 'no-mistakes'):
            shutil.copy2(FIXTURES / 'forge.py', fakebin / name)
        self.env = dict(os.environ, FM_JOURNAL_WORLD=str(self.world),
                        FM_JOURNAL_FIXTURES=str(FIXTURES), FM_HOME=str(self.home),
                        FM_STATE_OVERRIDE=str(self.state), FM_ROOT_OVERRIDE=str(ROOT),
                        GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_DATE='2026-01-01T00:00:00+0000',
                        GIT_COMMITTER_DATE='2026-01-01T00:00:00+0000',
                        PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
        self.git('init', '-q', '-b', 'topic')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'core.autocrlf', 'false')
        (self.repo / 'docs').mkdir()
        page = self.repo / 'docs/intro.md'
        page.write_text('A useful sentence.  \n')
        self.git('add', '.')
        self.git('commit', '-qm', 'Base')
        page.write_text('A useful sentence.\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'Presentation')
        self.assertEqual(self.git('rev-parse', 'HEAD'), HEAD, 'static evidence must bind actual Git objects')
        meta = self.state / 'task.meta'
        meta.write_text(f'worktree={self.repo}\nmode=no-mistakes\npr={URL}\npr_head={HEAD}\nyolo=on\n')
        meta.chmod(0o600)
        self.mode('confirmed')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], env=self.env, text=True).strip()

    def mode(self, value):
        (self.world / 'mode').write_text(value)

    def command(self, script, *args):
        return subprocess.run(['bash', str(ROOT / 'bin' / script), *args],
                              env=self.env, capture_output=True, text=True)

    def merge(self, automatic=True):
        return self.command('fm-pr-merge.sh', 'task', URL, *(['--automatic'] if automatic else []))

    def recover(self):
        return subprocess.run(['bash', str(FIXTURES / 'recover.sh'), str(ROOT), str(self.home), URL],
                              env=self.env, capture_output=True, text=True)

    def journal(self):
        path = self.home / 'data/auto-merge-journal.tsv'
        return path.read_text().splitlines() if path.is_file() else []

    def assert_receipt(self):
        self.assertEqual(self.journal(), [f'{URL}\t{HEAD}\t2\t1\t2026-10-15T12:30:00Z'])

    def bind_excluded_note(self):
        self.mode('zero-files')
        shutil.rmtree(self.repo)
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'topic')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'core.autocrlf', 'false')
        note = self.repo / 'tests/fixtures/note.md'
        note.parent.mkdir(parents=True)
        note.write_text('A useful sentence.  \n')
        self.git('add', '.')
        self.git('commit', '-qm', 'Base')
        note.write_text('A useful sentence.\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'Presentation')
        self.assertEqual(self.git('rev-parse', 'HEAD'), ZERO_HEAD)
        meta = self.state / 'task.meta'
        meta.write_text(meta.read_text().replace(f'pr_head={HEAD}', f'pr_head={ZERO_HEAD}'))
        meta.chmod(0o600)

    def test_zero_file_eligible_snapshot_is_journaled(self):
        self.bind_excluded_note()
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.world / 'accepted').exists())
        self.assertEqual(self.journal(), [f'{URL}\t{ZERO_HEAD}\t0\t0\t2026-10-15T12:30:00Z'])
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.journal(), [f'{URL}\t{ZERO_HEAD}\t0\t0\t2026-10-15T12:30:00Z'])

    def test_transparent_fixture_eligibility(self):
        result = self.command('fm-auto-merge-check.sh', 'task', URL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        proof = json.loads(result.stdout)
        self.assertEqual((proof['head'], proof['lines'], proof['files']), (HEAD, 2, 1))
        self.assertFalse((self.world / 'accepted').exists())

    def test_confirmed_automatic_merge_and_idempotence(self):
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_receipt()
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_receipt()

    def test_attended_merge_is_not_automatic(self):
        result = self.merge(automatic=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.world / 'accepted').exists())
        self.assertEqual(self.journal(), [])

    def test_queued_request_does_not_journal(self):
        self.mode('queued')
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.journal(), [])
        self.assertFalse((self.state / 'task.pr-poll-merge-notified').exists())

    def test_failed_attempt_does_not_journal(self):
        self.mode('failed')
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal(), [])
        self.assertFalse((self.state / 'task.merge-authority').exists())

    def test_b1_refusal_stops_automatic_merge(self):
        self.mode('ineligible')
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.world / 'accepted').exists())
        self.assertEqual(self.journal(), [])

    def test_recovery_after_journal_destination_failure(self):
        path = self.home / 'data/auto-merge-journal.tsv'
        path.mkdir()
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('could not record the outcome', result.stderr)
        self.assertFalse((self.state / 'task.pr-poll-merge-notified').exists())
        path.rmdir()
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_receipt()
        self.assertEqual(self.recover().returncode, 0)
        self.assert_receipt()

    def test_other_landed_head_is_never_journaled(self):
        self.mode('wrong-head')
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.journal(), [])
        self.assertFalse((self.state / 'task.pr-poll-merge-notified').exists())

    def test_accepted_unreadable_outcome_recovers(self):
        self.mode('unreadable')
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.world / 'accepted').exists())
        self.assertEqual(self.journal(), [])
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_receipt()

    def test_automatic_requires_standing_authority(self):
        meta = self.state / 'task.meta'
        meta.write_text(meta.read_text().replace('yolo=on', 'yolo=off'))
        result = self.merge()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.world / 'accepted').exists())

    def test_automatic_cannot_use_attended_overrides(self):
        for flags in (['--attended-override'], ['--allow-red', 'ci'], ['--', '--auto']):
            with self.subTest(flags=flags):
                result = self.command('fm-pr-merge.sh', 'task', URL, '--automatic', *flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.world / 'accepted').exists())

    def test_recovery_rejects_misbound_evidence(self):
        path = self.home / 'data/auto-merge-journal.tsv'
        path.mkdir()
        self.merge()
        path.rmdir()
        record = self.state / 'task.merge-authority'
        original = record.read_text()
        record.write_text(original.replace(URL, 'https://github.com/example/repo/pull/8'))
        result = self.recover()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal(), [])
        self.assertFalse((self.state / 'task.pr-poll-merge-notified').exists())
        record.write_text(original)
        self.assertEqual(self.recover().returncode, 0)
        self.assert_receipt()

if __name__ == '__main__':
    unittest.main()
