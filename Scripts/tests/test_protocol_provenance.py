"""验证协议来源版本不受仓库布局、无关提交或未提交输入影响。"""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('protocol_sync', Path(__file__).parents[1] / 'sync-server-protocol.py')
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)

class ProtocolProvenanceTests(unittest.TestCase):
    def git(self, root, *args):
        return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout.strip()

    def verify_layout(self, embedded):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = root / 'AzureFishServer' if embedded else root
            server.mkdir(exist_ok=True)
            self.git(root, 'init', '-q')
            self.git(root, 'config', 'user.name', 'Fixture')
            self.git(root, 'config', 'user.email', 'fixture@example.invalid')
            paths = ['Protos/generation.json', 'Protos/azurefish.proto', 'Sources/Server/Protocol/azurefish.pb.swift', 'Package.resolved']
            for name in paths:
                path = server / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fictional protocol input')
            self.assertIsNone(SYNC.committed_server_revision(server))
            self.git(root, 'add', '.')
            self.git(root, 'commit', '-qm', '协议输入')
            revision = self.git(root, 'rev-parse', 'HEAD')
            self.assertEqual(SYNC.committed_server_revision(server), revision)
            (root / 'unrelated.txt').write_text('unrelated')
            self.git(root, 'add', '.')
            self.git(root, 'commit', '-qm', '无关修改')
            self.assertEqual(SYNC.committed_server_revision(server), revision)
            (server / paths[1]).write_text('changed protocol')
            self.assertIsNone(SYNC.committed_server_revision(server))
            self.git(root, 'add', '.')
            self.assertIsNone(SYNC.committed_server_revision(server))
            self.git(root, 'commit', '-qm', '更新协议输入')
            self.assertEqual(SYNC.committed_server_revision(server), self.git(root, 'rev-parse', 'HEAD'))

    def test_standalone_repository(self):
        self.verify_layout(False)

    def test_embedded_server(self):
        self.verify_layout(True)

if __name__ == '__main__':
    unittest.main()
