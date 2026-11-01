import concurrent.futures
import io
import importlib
import json
import os
from pathlib import Path
import tempfile
import unittest


class VotingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        os.environ['DATABASE_PATH'] = str(Path(cls.tmp.name) / 'votes.db')
        os.environ.pop('REDIS_HOST', None)
        cls.app = importlib.import_module('app')
    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def request(self, method, path, body=None):
        # Exercise the actual HTTP handler without opening a network socket.
        payload = (body or '').encode()
        raw = (f'{method} {path} HTTP/1.0\r\n'
               f'Content-Length: {len(payload)}\r\n'
               'Content-Type: application/json\r\n\r\n').encode() + payload
        class Connection:
            def __init__(self):
                self.output = bytearray()
            def makefile(self, *args):
                return io.BytesIO(raw)
            def sendall(self, data):
                self.output.extend(data)
        connection = Connection()
        self.app.Handler(connection, ('127.0.0.1', 0), None)
        headers, data = bytes(connection.output).split(b'\r\n\r\n', 1)
        return int(headers.split()[1]), data

    def test_page_and_health(self):
        status, body = self.request('GET', '/')
        self.assertEqual(status, 200)
        self.assertIn(b'The great', body)
        for endpoint in ('/healthz', '/readyz'):
            self.assertEqual(self.request('GET', endpoint)[0], 200)
        self.assertEqual(self.request('GET', '/missing')[0], 404)

    def test_bad_votes_do_not_change_totals(self):
        before = self.app.totals()
        for body in ('{}', '[]', '{', '{"choice":"birds"}', '{"choice":null}'):
            self.assertEqual(self.request('POST', '/api/vote', body)[0], 400)
        self.assertEqual(self.app.totals(), before)

    def test_concurrent_votes_and_persistence(self):
        before = self.app.totals()['cats']
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            statuses = list(pool.map(lambda _: self.request('POST', '/api/vote', '{"choice":"cats"}')[0], range(20)))
        self.assertEqual(statuses, [200] * 20)
        self.assertEqual(self.app.totals()['cats'], before + 20)
        status, body = self.request('GET', '/api/results')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['votes']['cats'], before + 20)
        with self.app.sqlite3.connect(self.app.DB) as conn:
            self.assertEqual(conn.execute("SELECT count FROM votes WHERE choice='cats'").fetchone()[0], before + 20)

    def test_storage_failure_returns_unavailable(self):
        original = self.app.totals
        def unavailable(choice=None):
            raise OSError('offline')
        self.app.totals = unavailable
        try:
            self.assertEqual(self.request('GET', '/readyz')[0], 503)
            self.assertEqual(self.request('GET', '/healthz')[0], 200)
            self.assertEqual(self.request('POST', '/api/vote', '{"choice":"dogs"}')[0], 503)
        finally:
            self.app.totals = original


if __name__ == '__main__':
    unittest.main()
