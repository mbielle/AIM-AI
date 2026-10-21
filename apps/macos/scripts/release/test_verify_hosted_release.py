"""Offline contracts: simulated HTTPS responses only, no real release download."""
import email.message, hashlib, importlib.util, io, pathlib, tempfile, unittest, unittest.mock, urllib.request

spec = importlib.util.spec_from_file_location('hosted', pathlib.Path(__file__).with_name('verify-hosted-release.py'))
hosted = importlib.util.module_from_spec(spec); spec.loader.exec_module(hosted)

class Response(io.BytesIO):
    def __init__(self, body, mime='application/xml', url='https://preview.example/updates/appcast.xml', status=200):
        super().__init__(body); self.headers = email.message.Message()
        self.headers['Content-Type'] = mime; self.headers['Content-Length'] = str(len(body))
        self.url = url; self.status = status
    def geturl(self): return self.url

class Opener:
    def __init__(self, response): self.response = response
    def open(self, request, timeout): return self.response

class HostedVerificationTests(unittest.TestCase):
    def fetch(self, response, body=b'xml', expected_size=None, limit=10, expected_sha=None):
        with tempfile.TemporaryDirectory(prefix='aim-hosted-test-') as directory:
            return hosted.fetch('https://preview.example/updates/appcast.xml', pathlib.Path(directory)/'fixture',
                expected_sha or hashlib.sha256(body).hexdigest(), limit, {'application/xml'},
                expected_size=expected_size, opener=Opener(response))

    def test_exact_bytes_streamed_and_hashed(self):
        self.assertEqual(self.fetch(Response(b'xml'))['bytes'], 3)

    def test_spa_html_with_200_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'MIME'):
            self.fetch(Response(b'<html>', mime='text/html'), body=b'<html>')

    def test_reused_filename_with_changed_content_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'Hash mismatch'):
            self.fetch(Response(b'old'), expected_sha=hashlib.sha256(b'new').hexdigest())

    def test_size_mismatch_and_partial_response_are_refused(self):
        with self.assertRaisesRegex(ValueError, 'size'):
            self.fetch(Response(b'xml'), expected_size=4)
        with self.assertRaisesRegex(ValueError, 'HTTP 200'):
            self.fetch(Response(b'xml', status=206))

    def test_oversized_response_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'size'):
            self.fetch(Response(b'12345678901'), body=b'12345678901')

    def test_http_redirect_is_refused_before_following(self):
        handler = hosted.HTTPSRedirects()
        with self.assertRaisesRegex(ValueError, 'HTTPS'):
            handler.redirect_request(urllib.request.Request('https://example.com/file'), None, 302, '', {}, 'http://example.com/file')

    def test_preview_only_changes_fetch_origin(self):
        self.assertEqual(hosted.target_url('https://aim-ai.tech/updates/appcast.xml', 'https://preview.example'), 'https://preview.example/updates/appcast.xml')
        with self.assertRaisesRegex(ValueError, 'origin'):
            hosted.target_url('https://aim-ai.tech/updates/appcast.xml', 'https://preview.example/prefix')

    def test_signed_enclosure_cannot_point_to_preview(self):
        configuration = {'application_build': '2', 'application_version': '0.1.0', 'sparkle_feed_url': 'https://aim-ai.tech/updates/appcast.xml'}
        data = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>2</sparkle:version><enclosure url="https://preview.example/updates/app.dmg" length="3"/></item></channel></rss>'
        with self.assertRaisesRegex(ValueError, 'production contract'):
            hosted.parse_feed(data, configuration, 'app.dmg', 3)

    def test_credentials_and_http_urls_are_refused(self):
        for url in ['http://example.com/feed', 'https://user:password@example.com/feed', 'https://example.com/feed?token=secret']:
            with self.assertRaises(ValueError): hosted.https(url)

    def test_existing_output_directory_refused_before_any_request(self):
        with tempfile.TemporaryDirectory(prefix='aim-existing-output-test-') as directory:
            arguments = ['verify', '--configuration', 'unused', '--feed-receipt', 'unused', '--artifact-receipt', 'unused', '--output-directory', directory]
            with unittest.mock.patch('sys.argv', arguments), unittest.mock.patch.object(hosted, 'fetch') as fetch:
                with self.assertRaisesRegex(ValueError, 'must be new'): hosted.main()
                fetch.assert_not_called()

if __name__ == '__main__': unittest.main()
