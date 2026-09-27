"""Stdlib-only loopback fixture; never binds a fixed application port."""
import base64
import hashlib
import http.server
import struct


def read_exact(stream, count):
    data = stream.read(count)
    if len(data) != count:
        raise EOFError()
    return data


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def frame(self, opcode, payload):
        size = len(payload)
        prefix = bytes([0x80 | opcode])
        if size < 126:
            prefix += bytes([size])
        elif size < 65536:
            prefix += bytes([126]) + struct.pack('!H', size)
        else:
            prefix += bytes([127]) + struct.pack('!Q', size)
        self.wfile.write(prefix + payload)
        self.wfile.flush()

    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(307)
            self.send_header('Location', '/echo')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/unauthorized':
            self.send_response(401)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        try:
            if self.path == '/large':
                self.frame(2, b'x' * 8192)
            if self.path == '/policy':
                self.frame(8, struct.pack('!H', 1008) + b'private reason')
            while True:
                first, second = read_exact(self.rfile, 2)
                opcode, size = first & 15, second & 127
                if size == 126:
                    size = struct.unpack('!H', read_exact(self.rfile, 2))[0]
                elif size == 127:
                    size = struct.unpack('!Q', read_exact(self.rfile, 8))[0]
                if size > 2 * 1024 * 1024:
                    return
                mask = read_exact(self.rfile, 4) if second & 128 else None
                payload = read_exact(self.rfile, size)
                if mask:
                    payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
                if opcode == 8:
                    self.frame(8, payload)
                    return
                if opcode == 9:
                    self.frame(10, payload)
                elif opcode in (1, 2):
                    self.frame(opcode, payload)
        except (EOFError, ConnectionError, OSError):
            pass
        finally:
            self.close_connection = True


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
