#!/usr/bin/env python3
"""对已启动的回环服务执行虚构账号闭环；凭据仅保存在进程内存，不打印。"""
import base64
import hashlib
import socket
import struct
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
PROTOC = os.environ.get("PROTOC", "protoc")
PORT = int(os.environ.get("AZUREFISH_SMOKE_PORT", "8080"))


def protobuf(message, data, decode=False):
    flag = "--decode=" if decode else "--encode="
    return subprocess.check_output(
        [PROTOC, "--proto_path=Protos", flag + "azurefish.v1." + message, "Protos/azurefish.proto"],
        input=data, cwd=ROOT,
    )


def call(method, path, message=None, fields=None, token=None, expected=200):
    headers = {"Accept": "application/protobuf", "Content-Type": "application/protobuf"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None
    if message:
        text = "\n".join(name + ": " + json.dumps(item) for name, value in fields.items() for item in (value if isinstance(value, list) else [value]))
        body = protobuf(message, text.encode())
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}" + path, data=body, headers=headers, method=method)
    # 回环请求不经过系统配置的代理。
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        response = opener.open(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.status == expected, (path, response.status, expected)
        assert response.headers.get_content_type() == "application/protobuf"
        assert response.headers["Cache-Control"] == "no-store"
        return response.read()


def field(message, name):
    match = re.search(r'^' + re.escape(name) + r': "([^"]*)"$', message.decode(), re.MULTILINE)
    assert match, name
    return match.group(1)


call("GET", "/health")
account = "smoke_" + uuid.uuid4().hex[:16]
registration = dict(operation_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()), account_name=account,
                    password="Fictional-Smoke-Password-123", nickname="Smoke test")
created = call("POST", "/v1/auth/register", "RegisterRequest", registration, expected=201)
assert call("POST", "/v1/auth/register", "RegisterRequest", registration, expected=201) == created
login = dict(operation_id=str(uuid.uuid4()), device_id=registration["device_id"], account_name=account, password=registration["password"])
logged_in = protobuf("AuthResponse", call("POST", "/v1/auth/login", "LoginRequest", login), decode=True)
access = field(logged_in, "access_token")
call("GET", "/v1/me", token=access)
patch = dict(operation_id=str(uuid.uuid4()), expected_profile_version=1, bio="Local smoke test")
call("PATCH", "/v1/me", "UpdateProfileRequest", patch, token=access)
renew = dict(operation_id=str(uuid.uuid4()), refresh_token=field(logged_in, "refresh_token"))
renewed = call("POST", "/v1/auth/refresh", "RefreshRequest", renew)
assert call("POST", "/v1/auth/refresh", "RefreshRequest", renew) == renewed
access = field(protobuf("AuthResponse", renewed, decode=True), "access_token")
call("POST", "/v1/auth/logout", "LogoutRequest", dict(operation_id=str(uuid.uuid4())), token=access)
call("GET", "/v1/me", token=access, expected=401)
print("PASS: health, register, login, profile, refresh recovery, logout, revoked access")


# IM 与实时提示同样只使用临时虚构账号。
def new_user():
    request = dict(operation_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                   account_name="im_smoke_" + uuid.uuid4().hex[:12],
                   password="Fictional-Smoke-Password-123", nickname="IM smoke")
    data = protobuf("AuthResponse", call("POST", "/v1/auth/register", "RegisterRequest", request, expected=201), decode=True)
    return {key: field(data, key) for key in ["user_id", "access_token", "device_id"]}


def number(message, name):
    match = re.search(r"^" + re.escape(name) + r": (\d+)$", message.decode(), re.MULTILINE)
    return int(match.group(1)) if match else 0


def receive_exact(stream, count):
    result = b""
    while len(result) < count:
        data = stream.recv(count - len(result))
        assert data, "WebSocket closed unexpectedly"
        result += data
    return result


def receive_frame(stream):
    first, second = receive_exact(stream, 2)
    assert first & 0x80 and not second & 0x80
    count = second & 0x7f
    if count == 126:
        count = struct.unpack("!H", receive_exact(stream, 2))[0]
    elif count == 127:
        count = struct.unpack("!Q", receive_exact(stream, 8))[0]
    assert count <= 4096
    return first & 0x0f, receive_exact(stream, count)


a, b = new_user(), new_user()
resolve = dict(operation_id=str(uuid.uuid4()), peer_user_id=b["user_id"])
conversation = protobuf("IMConversation", call("POST", "/v1/im/conversations/resolve", "IMResolveRequest", resolve, token=a["access_token"]), decode=True)
conversation_id = field(conversation, "conversation_id")
message = dict(operation_id=str(uuid.uuid4()), conversation_id=conversation_id,
               message_uuid=str(uuid.uuid4()), client_message_id=str(uuid.uuid4()),
               device_id=a["device_id"], content_type="text", content_schema_version=1,
               text="Fictional IM smoke message")
call("GET", "/v1/im/live", expected=401)
with socket.create_connection(("127.0.0.1", PORT), timeout=10) as stream:
    stream.settimeout(10)
    key = base64.b64encode(os.urandom(16)).decode()
    handshake = (f"GET /v1/im/live HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n"
                 "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                 f"Sec-WebSocket-Key: {key}\r\nAuthorization: Bearer {b['access_token']}\r\n\r\n")
    stream.sendall(handshake.encode())
    headers = b""
    while not headers.endswith(b"\r\n\r\n"):
        headers += receive_exact(stream, 1)
        assert len(headers) < 8192
    assert b"101 Switching Protocols" in headers
    expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
    assert expected.lower() in headers.lower()
    opcode, initial = receive_frame(stream)
    assert opcode == 2
    before = field(protobuf("IMSyncHint", initial, decode=True), "latest_cursor")
    sent = call("POST", "/v1/im/messages/send", "IMSendRequest", message, token=a["access_token"])
    assert call("POST", "/v1/im/messages/send", "IMSendRequest", message, token=a["access_token"]) == sent
    opcode, changed = receive_frame(stream)
    assert opcode == 2
    hint = protobuf("IMSyncHint", changed, decode=True)
    assert field(hint, "latest_cursor") != before
    event_page = protobuf("IMEventsResponse", call("POST", "/v1/im/events", "IMEventsRequest",
                          dict(cursor=before, epoch=field(hint, "epoch")), token=b["access_token"]), decode=True)
    assert b"Fictional IM smoke message" in event_page
    call("POST", "/v1/auth/logout", "LogoutRequest", dict(operation_id=str(uuid.uuid4())), token=b["access_token"])
    opcode, _ = receive_frame(stream)
    assert opcode == 8, "Revoked session must close its live connection"

history = protobuf("IMHistoryResponse", call("POST", "/v1/im/history", "IMHistoryRequest", dict(conversation_id=conversation_id), token=a["access_token"]), decode=True)
assert number(history, "upper_bound_seq") == 1
revoke = dict(operation_id=str(uuid.uuid4()), conversation_id=conversation_id, message_uuid=message["message_uuid"])
call("POST", "/v1/im/messages/revoke", "IMRevokeRequest", revoke, token=a["access_token"])
retry = protobuf("IMMessage", call("POST", "/v1/im/messages/send", "IMSendRequest", message, token=a["access_token"]), decode=True)
assert b"revoked: true" in retry and b"Fictional IM smoke message" not in retry
created_group = protobuf("IMConversation", call("POST", "/v1/im/groups/create", "IMCreateGroupRequest",
                        dict(operation_id=str(uuid.uuid4()), title="Fictional smoke group", member_user_ids=[b["user_id"]]), token=a["access_token"]), decode=True)
call("POST", "/v1/im/groups/update", "IMUpdateGroupRequest",
     dict(operation_id=str(uuid.uuid4()), conversation_id=field(created_group, "conversation_id"), expected_revision=1, action="dissolve"), token=a["access_token"])
call("POST", "/v1/im/snapshot", "IMSnapshotRequest", dict(limit=1), token=a["access_token"])
print("PASS: IM direct, group, send retry, history, revoke, snapshot, live binary hint, incremental recovery, logout closes live socket")
