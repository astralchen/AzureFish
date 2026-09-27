#!/usr/bin/env python3
"""由集成测试通过 stdin 提供临时凭据；验证慢上传期间控制接口响应及取消竞态。"""
import base64
import hashlib
import http.client
import json
import socket
import sys
import time

config = json.load(sys.stdin)
body = b"s" * (4 * 1024 * 1024)
connection = socket.create_connection(("127.0.0.1", config["port"]), timeout=10)
header = (f"PUT /v1/media/uploads/{config['upload']}/parts/0 HTTP/1.1\r\n"
          f"Host: 127.0.0.1\r\nAuthorization: Bearer {config['token']}\r\n"
          f"Content-Type: application/octet-stream\r\nX-Content-SHA256: {hashlib.sha256(body).hexdigest()}\r\n"
          f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()
connection.sendall(header + body[:65536])
time.sleep(0.2)
control = http.client.HTTPConnection("127.0.0.1", config["port"], timeout=3)
started = time.monotonic()
control.request("GET", "/v1/me", headers={"Authorization": "Bearer " + config["token"]})
response = control.getresponse()
assert response.status == 200
response.read()
control.request("POST", config["control_path"], body=base64.b64decode(config["control_body"]),
                headers={"Authorization": "Bearer " + config["token"], "Content-Type": "application/protobuf"})
response = control.getresponse()
assert response.status == 200
response.read()
assert time.monotonic() - started < 2, "control routes blocked behind upload"
for offset in range(65536, len(body), 65536):
    connection.sendall(body[offset:offset + 65536])
    time.sleep(0.003)
response = http.client.HTTPResponse(connection)
response.begin()
assert response.status == config["expected"], response.status
response.read()
connection.close()
control.close()
print("PASS: slow byte upload leaves account/text controls responsive; cancellation is authoritative")
