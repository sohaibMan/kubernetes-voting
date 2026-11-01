"""Small voting server: SQLite locally, shared Redis in containers."""
import json
import os
from pathlib import Path
import socket
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).parent
POD = os.getenv('HOSTNAME', socket.gethostname())
DB = os.getenv('DATABASE_PATH', str(ROOT / 'votes.db'))
REDIS_HOST = os.getenv('REDIS_HOST')
if REDIS_HOST:
    import redis
    store = redis.Redis(host=REDIS_HOST, port=6379, socket_timeout=2, socket_connect_timeout=2)
else:
    with sqlite3.connect(DB) as conn:
        conn.execute('CREATE TABLE IF NOT EXISTS votes (choice TEXT PRIMARY KEY, count INTEGER NOT NULL)')


def totals(choice=None):
    if REDIS_HOST:
        if choice:
            store.hincrby('votes', choice, 1)
        values = store.hgetall('votes')
        return {key: int(values.get(key.encode(), 0)) for key in ('cats', 'dogs')}
    with sqlite3.connect(DB, timeout=5) as conn:
        if choice:
            conn.execute('INSERT INTO votes VALUES (?, 1) ON CONFLICT(choice) DO UPDATE SET count=count+1', (choice,))
        values = dict(conn.execute('SELECT choice, count FROM votes'))
    return {key: values.get(key, 0) for key in ('cats', 'dogs')}


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, data, content_type='application/json'):
        body = json.dumps(data).encode() if content_type == 'application/json' else data
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/healthz':
            return self.reply(200, {'status': 'ok', 'pod': POD})
        if path in ('/api/results', '/readyz'):
            try:
                return self.reply(200, {'votes': totals(), 'pod': POD, 'storage': 'redis' if REDIS_HOST else 'sqlite'})
            except Exception:
                return self.reply(503, {'error': 'Vote storage unavailable'})
        if path == '/':
            return self.reply(200, (ROOT / 'public/index.html').read_bytes(), 'text/html; charset=utf-8')
        self.reply(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path != '/api/vote':
            return self.reply(404, {'error': 'Not found'})
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 1024:
                return self.reply(400, {'error': 'Expected a small JSON body'})
            data = json.loads(self.rfile.read(size))
            choice = data.get('choice') if isinstance(data, dict) else None
            if choice not in ('cats', 'dogs'):
                return self.reply(400, {'error': 'Choose cats or dogs'})
        except (ValueError, UnicodeDecodeError):
            return self.reply(400, {'error': 'Invalid JSON'})
        try:
            self.reply(200, {'votes': totals(choice), 'pod': POD})
        except Exception:
            self.reply(503, {'error': 'Vote storage unavailable'})


if __name__ == '__main__':
    port = int(os.getenv('PORT', '8080'))
    print(f'Voting app: http://localhost:{port}', flush=True)
    ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()
