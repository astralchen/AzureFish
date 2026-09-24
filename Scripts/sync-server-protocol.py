#!/usr/bin/env python3
"""从唯一权威服务端同步已生成的 Swift 类型；不复制 .proto，也不修改服务端。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def committed_server_revision(server):
    # 嵌入客户端仓库后，不能把父仓库 HEAD 误当成尚未提交的协议来源。
    paths = ['Protos/generation.json', 'Protos/azurefish.proto',
             'Sources/Server/Protocol/azurefish.pb.swift', 'Package.resolved']
    tracked = subprocess.run(
        ['git', '-C', str(server), 'ls-files', '--error-unmatch', '--', *paths],
        capture_output=True, text=True)
    if tracked.returncode != 0:
        return None
    status = subprocess.run(
        ['git', '-C', str(server), 'status', '--porcelain', '--', *paths],
        capture_output=True, text=True)
    if status.returncode != 0 or status.stdout.strip():
        return None
    revision = subprocess.run(
        ['git', '-C', str(server), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    return revision.stdout.strip() if revision.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True, help='AzureFishServer 根目录')
    parser.add_argument('--check', action='store_true', help='只比较，不写入')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    package = root / 'SharePackage/AzureFishProtocol'
    server = args.server.resolve()
    manifest = json.loads((server / 'Protos/generation.json').read_text())
    schema = (server / 'Protos/azurefish.proto').read_bytes()
    generated = (server / 'Sources/Server/Protocol/azurefish.pb.swift').read_bytes()
    if digest(schema) != manifest['schema_sha256']:
        raise SystemExit('服务端 schema hash 不匹配，请先重新生成协议。')
    if b'// DO NOT EDIT.' not in generated or b'// Source: azurefish.proto' not in generated:
        raise SystemExit('缺少预期的 SwiftProtobuf 生成标记。')
    pins = json.loads((server / 'Package.resolved').read_text())['pins']
    pin = next(p for p in pins if p['identity'] == 'swift-protobuf')['state']
    if pin['version'] != manifest['swift_protobuf_version'] or pin['revision'] != manifest['swift_protobuf_revision']:
        raise SystemExit('服务端生成清单与运行库锁定版本不一致。')
    for target in [package, root / 'SharePackage/AzureFishAPI']:
        versions = re.findall(r'exact:\s*"([^"]+)"', (target / 'Package.swift').read_text())
        if versions != [manifest['swift_protobuf_version']]:
            raise SystemExit('先审查并更新本地包的 SwiftProtobuf 精确版本，再同步生成产物。')
    manifest['server_revision'] = committed_server_revision(server)
    manifest['generated_swift_sha256'] = digest(generated)
    outputs = {
        package / 'Sources/AzureFishProtocol/Generated/azurefish.pb.swift': generated,
        package / 'generation.json': (json.dumps(manifest, indent=2) + '\n').encode(),
    }
    for path, data in outputs.items():
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit('协议快照不同步：' + str(path.relative_to(root)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(path.suffix + '.tmp')
            temporary.write_bytes(data)
            temporary.replace(path)
    print('协议快照检查通过' if args.check else '已同步协议 Swift 文件及来源清单')


if __name__ == '__main__':
    main()
