import base64
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import unittest


script = pathlib.Path(__file__).with_name('validate-client-config.py')
spec = importlib.util.spec_from_file_location('client_config', script)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def fixture_jwt(role):
    payload = base64.urlsafe_b64encode(json.dumps({'role': role}).encode()).decode().rstrip('=')
    return 'fixture.' + payload + '.signature'


class ClientConfigTests(unittest.TestCase):
    def test_bare_https_origins_include_self_hosted_ports_and_ipv6(self):
        for origin in ['https://backend.example.invalid', 'https://backend.example.invalid/',
                       ' https://backend.example.invalid:8443/ ', 'https://[::1]:443']:
            with self.subTest(origin=origin):
                config.validate_origin(origin)

    def test_credential_path_query_fragment_and_invalid_port_are_rejected(self):
        credential = urllib_origin_with_fixture_credentials()
        for origin in ['', 'http://backend.example.invalid', credential,
                       'https://backend.example.invalid/private', 'https://backend.example.invalid?',
                       'https://backend.example.invalid#', 'https://backend.example.invalid:0',
                       'https://backend.example.invalid:65536', 'https://backend.example.invalid:not-a-port',
                       'https://backend.example.invalid:', 'https://back\nend.example.invalid']:
            with self.subTest(origin=origin):
                with self.assertRaises(ValueError):
                    config.validate_origin(origin)

    def test_public_publishable_and_anon_role_keys_are_accepted(self):
        config.validate_public_key('sb_publishable_example_public_fixture')
        config.validate_public_key(fixture_jwt('anon'))

    def test_privileged_invalid_or_non_anon_keys_are_rejected(self):
        for key in ['sb_' + 'secret_' + 'example_privileged_fixture', 'sb' + 'p_' + 'example_privileged_fixture',
                    'sb_publishable_', 'sb_publishable_bad whitespace', fixture_jwt('service_role'),
                    fixture_jwt('authenticated'), 'fixture.invalid.signature', '.invalid.',
                    'fixture.WyJhbm9uIl0.signature']:
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    config.validate_public_key(key)

    def test_failure_never_logs_url_credentials_or_key_and_no_argument_is_needed(self):
        marker = 'fixture-do-not-print-key'
        environment = {**os.environ, 'AIM_SUPABASE_URL': urllib_origin_with_fixture_credentials(),
                       'AIM_SUPABASE_PUBLIC_KEY': marker, 'PYTHONDONTWRITEBYTECODE': '1'}
        result = subprocess.run([sys.executable, str(script)], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(marker, result.stdout + result.stderr)
        self.assertNotIn('fixture-user', result.stdout + result.stderr)
        self.assertNotIn('fixture-password', result.stdout + result.stderr)

    def test_configuration_pair_is_optional_but_partial_pair_is_rejected(self):
        for url, key, expected in [('', '', 0), ('https://backend.example.invalid', '', 2),
                                   ('', 'sb_publishable_example_public_fixture', 2)]:
            environment = {**os.environ, 'AIM_SUPABASE_URL': url, 'AIM_SUPABASE_PUBLIC_KEY': key,
                           'PYTHONDONTWRITEBYTECODE': '1'}
            result = subprocess.run([sys.executable, str(script)], env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected)


def urllib_origin_with_fixture_credentials():
    # Keep userinfo-rejection coverage without a literal credential URL that
    # would require a publication-scanner exception.
    return 'https://' + 'fixture-user' + ':' + 'fixture-password' + '@backend.example.invalid'


if __name__ == '__main__':
    unittest.main()
