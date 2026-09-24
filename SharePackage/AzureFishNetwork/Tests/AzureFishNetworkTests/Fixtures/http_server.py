import http.server
import time


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    count = 0

    def log_message(self, *args):
        pass

    def do_GET(self):
        Handler.count += 1
        if self.path == '/redirect':
            self.send_response(307)
            self.send_header('Location', '/sink')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = str(Handler.count).encode()
        if self.path in ['/large', '/unknown-length']:
            body = b'a' * 16384
        self.send_response(200)
        self.send_header('Cache-Control', 'public, max-age=3600')
        self.send_header('Set-Cookie', 'fictional=value')
        self.send_header('X-Received-Cookie', self.headers.get('Cookie', 'none'))
        if self.path == '/unknown-length':
            self.send_header('Connection', 'close')
            self.close_connection = True
        else:
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.flush()
        if self.path == '/slow':
            time.sleep(3)
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
