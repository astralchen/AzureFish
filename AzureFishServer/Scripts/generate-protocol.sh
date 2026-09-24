#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
PROTOC_BIN="${PROTOC:-protoc}"
swift build --product protoc-gen-swift
SWIFT_BIN="$(swift build --show-bin-path)"
"$PROTOC_BIN" --proto_path=Protos \
  --plugin="protoc-gen-swift=$SWIFT_BIN/protoc-gen-swift" \
  --swift_out=Sources/Server/Protocol --swift_opt=Visibility=Public \
  Protos/azurefish.proto
python3 - <<'PY'
import hashlib, json, os, subprocess
from pathlib import Path

pins = json.loads(Path('Package.resolved').read_text())['pins']
protobuf = next(pin for pin in pins if pin['identity'] == 'swift-protobuf')
data = {
    'schema_sha256': hashlib.sha256(Path('Protos/azurefish.proto').read_bytes()).hexdigest(),
    'swift_protobuf_version': protobuf['state']['version'],
    'swift_protobuf_revision': protobuf['state']['revision'],
    'protoc_version': subprocess.check_output([os.environ.get('PROTOC', 'protoc'), '--version'], text=True).strip(),
}
Path('Protos/generation.json').write_text(json.dumps(data, indent=2) + '\n')
PY
