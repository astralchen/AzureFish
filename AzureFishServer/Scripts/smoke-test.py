#!/usr/bin/env python3
"""对已启动的回环服务执行虚构账号闭环；凭据仅保存在进程内存，不打印。"""
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
        text = "\n".join(name + ": " + json.dumps(value) for name, value in fields.items())
        body = protobuf(message, text.encode())
    request = urllib.request.Request("http://127.0.0.1:8080" + path, data=body, headers=headers, method=method)
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
