#!/usr/bin/env python3
"""Copy an xctestrun without changing build products; configure benchmark or unit-test candidates."""
import argparse
import pathlib
import plistlib

p = argparse.ArgumentParser()
p.add_argument('source', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--pairs', type=int, default=20)
p.add_argument('--limit', type=int, choices=[1, 2])
p.add_argument('--cooldown', type=float, default=10, help='Equal pre-launch cooldown seconds outside measurements')
args = p.parse_args()
assert args.pairs > 0
assert args.cooldown >= 0
root = args.source.resolve().parent

def relocate(value):
    if isinstance(value, str): return value.replace('__TESTROOT__', str(root))
    if isinstance(value, list): return [relocate(x) for x in value]
    if isinstance(value, dict): return {k: relocate(v) for k, v in value.items()}
    return value

run = relocate(plistlib.loads(args.source.read_bytes()))
targets = [t for c in run.get('TestConfigurations', []) for t in c.get('TestTargets', [])]
if not targets:
    targets = [v for k, v in run.items() if not k.startswith('__') and isinstance(v, dict)]
for target in targets:
    target.setdefault('EnvironmentVariables', {}).update(MEDIA_BENCHMARK_RUN='1', MEDIA_BENCHMARK_PAIRS=str(args.pairs), MEDIA_BENCHMARK_COOLDOWN_SECONDS=str(args.cooldown))
    if args.limit:
        target['EnvironmentVariables']['MEDIA_BENCHMARK_EXPECTED_LIMIT'] = str(args.limit)
        target.setdefault('CommandLineArguments', []).extend(['-media-work-limit', str(args.limit)])
args.output.write_bytes(plistlib.dumps(run))
print(args.output)
