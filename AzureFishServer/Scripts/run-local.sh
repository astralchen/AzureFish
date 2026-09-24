#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
umask 077
export AZUREFISH_ALLOW_LOCAL_TEST_DATA=1
export AZUREFISH_DATA_DIRECTORY="$(pwd)/.local/test-data"
export AZUREFISH_KEY_FILE="$(pwd)/.local/server.key"
python3 - <<'PY'
import os
from pathlib import Path

key = Path(os.environ['AZUREFISH_KEY_FILE'])
database = Path(os.environ['AZUREFISH_DATA_DIRECTORY']) / 'server.sqlite'
key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
if not key.exists():
    if database.exists():
        raise SystemExit('Existing database has no key. Restore the original key; no files were replaced.')
    descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(os.urandom(32))
        stream.flush()
        os.fsync(stream.fileno())
PY
exec swift run -j 4 AzureFishServer
