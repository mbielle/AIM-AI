#!/usr/bin/env python3
"""Regression: launch mistakes and failed scenarios exit normally, never SIGTRAP.

Run after build-swift-probe.py: --probe /path/to/aim-direct-controller-probe.
No model, server, pairing, app data or real device is used.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--probe', required=True, type=Path)
args = parser.parse_args()
probe = str(args.probe.resolve(strict=True))


class ProbeLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='aim-direct-launcher-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = dict(os.environ, CFFIXED_USER_HOME=str(self.root / 'home'))

    def launch(self, *arguments):
        return subprocess.run([probe, *arguments], capture_output=True, text=True,
                              env=self.env, timeout=15)

    def test_reopen_without_arguments_is_normal_usage_exit(self):
        result = self.launch()
        self.assertEqual(result.returncode, 64)
        self.assertIn('not an interactive AIM application', result.stderr)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_help_succeeds_without_creating_profile(self):
        result = self.launch('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('qualify-controller.py', result.stdout)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_unknown_mode_does_not_create_secrets(self):
        result = self.launch('unknown-mode', str(self.root))
        self.assertEqual(result.returncode, 64)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_failed_scenario_exits_one_instead_of_swift_error_in_main(self):
        result = self.launch('phone-reconnect', str(self.root))
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.root / 'phone-secrets').is_dir())
        self.assertIn('qualification failed', result.stderr)
        self.assertNotIn('Fatal error', result.stderr)
        self.assertNotIn('swift_errorInMain', result.stderr)


    def test_relative_root_rejected_without_creating_profile(self):
        result = self.launch('host', 'relative-qa-root')
        self.assertEqual(result.returncode, 64)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_invalid_relay_arguments_are_normal_usage_exit(self):
        result = self.launch('host', str(self.root), 'not-a-coordinator', '--relay')
        self.assertEqual(result.returncode, 64)
        self.assertEqual(list(self.root.iterdir()), [])


unittest.main(argv=['test-probe-launcher'])
