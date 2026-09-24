#!/usr/bin/env python3
"""Summarize paired app events and XCTest metrics; incomplete evidence never selects a winner."""
import argparse
import json
import math
import pathlib
import statistics

SCENES = {'cold': 'testColdImport', 'preview': 'testPreviewDuringImport', 'scroll': 'testScrollDuringImport', 'warm': 'testWarmPreview'}

def p90(values):
    """Nearest-rank P90, recorded explicitly so report readers can reproduce it."""
    return sorted(values)[math.ceil(len(values) * .9) - 1]

def summarize(logs, metrics, hitch_rows=(), *, pairs=20, selected_scenes=None):
    selected_scenes = selected_scenes or list(SCENES)
    expected_samples = pairs * 2
    formal = pairs == 20 and set(selected_scenes) == set(SCENES)
    samples = []
    for log in logs:
        for line in log.splitlines():
            if 'MEDIA_AB_SAMPLE ' in line:
                row = json.loads(line.split('MEDIA_AB_SAMPLE ', 1)[1])
                if row.get('measured'): samples.append(row)
    missing, failures, scenes = [], [], {}
    if samples and any(r.get('physicalDevice') is not True for r in samples):
        missing.append('physical-device provenance missing: simulator samples cannot select a winner')
    for scene in selected_scenes:
        method = SCENES[scene]
        rows = [r for r in samples if r['scenario'] == scene]
        keys = {(r['pair'], r['limit']) for r in rows}
        if len(rows) != expected_samples or keys != {(p, n) for p in range(pairs) for n in (1, 2)} or {r['sample'] for r in rows} != set(range(expected_samples)):
            missing.append(f'{scene}: requires exactly {pairs} distinct complete pairs, received {len(rows)} samples')
            continue
        for r in rows:
            if r.get('memoryWarnings') != 0 or r.get('remainingFiles') != 0 or r.get('thermalInvalid') or r.get('lowPowerInvalid'):
                missing.append(f'{scene}: invalid environment/resources in sample {r["sample"]}')
        if scene == 'preview' and any(r.get('previewOverlappedImport') is not True for r in rows):
            missing.append('preview: no verified overlap between preview and import')
        if scene == 'scroll' and any(r.get('overlappingScrollSteps', 0) <= 0 for r in rows):
            missing.append('scroll: no verified overlap between import and scrolling')
        runs = [run for test in metrics if f'/{method}(' in test.get('testIdentifier', '') for run in test.get('testRuns', [])]
        memory = next((m for run in runs for m in run.get('metrics', []) if m['identifier'].endswith('.physical_peak')), None)
        cpu = next((m for run in runs for m in run.get('metrics', []) if 'XCTMetric_CPU' in m['identifier'] and m['identifier'].endswith('.time')), None)
        hitch = next((m for run in runs for m in run.get('metrics', []) if 'XCTMetric_Hitch' in m['identifier'] and m['identifier'].endswith('.time.ratio')), None)
        result = {}
        for limit in (1, 2):
            selected = [r for r in rows if r['limit'] == limit]
            originals = [s['milliseconds'] for r in selected for s in r.get('originals', [])]
            result[str(limit)] = {
                'allReadyMedianMs': statistics.median(r['allReadyMs'] for r in selected),
                'allReadyP90Ms': p90([r['allReadyMs'] for r in selected]),
                'firstReadyMedianMs': statistics.median(r['firstReadyMs'] for r in selected),
                'firstReadyP90Ms': p90([r['firstReadyMs'] for r in selected]),
                'originalReadyMedianMs': statistics.median(originals) if originals else None,
                'originalReadyP90Ms': p90(originals) if originals else None,
            }
            if memory and memory.get('unitOfMeasurement') == 'kB' and len(memory.get('measurements', [])) == expected_samples:
                result[str(limit)]['peakMemoryMedianMB'] = statistics.median(memory['measurements'][r['sample']] for r in selected) / 1000
                result[str(limit)]['peakMemoryP90MB'] = p90([memory['measurements'][r['sample']] for r in selected]) / 1000
            else: missing.append(f'{scene}: missing aligned {expected_samples}-sample peak memory (kB)')
            if cpu and len(cpu.get('measurements', [])) == expected_samples:
                result[str(limit)]['cpuMedianSeconds'] = statistics.median(cpu['measurements'][r['sample']] for r in selected)
                result[str(limit)]['cpuP90Seconds'] = p90([cpu['measurements'][r['sample']] for r in selected])
            # Native measurements remain reportable even when long-stall attribution still needs a trace.
            if hitch and hitch.get('unitOfMeasurement') == 'ms per s' and len(hitch.get('measurements', [])) == expected_samples:
                result[str(limit)]['hitchRatioMedianMsPerSecond'] = statistics.median(hitch['measurements'][r['sample']] for r in selected)
                result[str(limit)]['hitchRatioP90MsPerSecond'] = p90([hitch['measurements'][r['sample']] for r in selected])
        a, b = result['1'], result['2']
        if 'peakMemoryMedianMB' in a and 'peakMemoryMedianMB' in b and b['peakMemoryMedianMB'] > a['peakMemoryMedianMB'] * 1.2:
            failures.append(f'{scene}: peak memory grows more than 20%')
        if scene in ('preview', 'warm'):
            if a['originalReadyP90Ms'] is None or b['originalReadyP90Ms'] is None: missing.append(f'{scene}: original readiness missing')
            elif b['originalReadyP90Ms'] - a['originalReadyP90Ms'] > max(50, a['originalReadyP90Ms'] * .1): failures.append(f'{scene}: original readiness P90 regression')
        if scene == 'cold':
            paired = {(r['pair'], r['limit']): r['allReadyMs'] for r in rows}
            result['bFasterPairs'] = sum(paired[p, 2] < paired[p, 1] for p in range(pairs))
            result['improvement'] = 1 - b['allReadyMedianMs'] / a['allReadyMedianMs']
            if formal and (result['improvement'] < .1 or result['bFasterPairs'] < 15): failures.append('cold: throughput benefit below 10% / 15 pairs')
        scenes[scene] = result
    # Trace review is mandatory for attribution of >100 ms stalls; a missing field is never treated as zero.
    for scene in selected_scenes:
        rows = [r for r in hitch_rows if r.get('scenario') == scene]
        if len(rows) != expected_samples or {(r.get('pair'), r.get('limit')) for r in rows} != {(p, n) for p in range(pairs) for n in (1, 2)}:
            missing.append(f'{scene}: missing paired Animation Hitches metrics and >100 ms attribution review')
            continue
        if any(not r.get('evidence') or not isinstance(r.get('ratioMsPerSecond'), (int, float)) or not isinstance(r.get('newMediaStallOver100ms'), bool) for r in rows):
            missing.append(f'{scene}: incomplete hitch evidence/attribution'); continue
        a = statistics.median(r['ratioMsPerSecond'] for r in rows if r['limit'] == 1)
        b = statistics.median(r['ratioMsPerSecond'] for r in rows if r['limit'] == 2)
        if b - a > max(1, a * .1) or any(r['newMediaStallOver100ms'] for r in rows if r['limit'] == 2): failures.append(f'{scene}: hitch regression')
        scenes.setdefault(scene, {})['hitchRatioMedianMsPerSecond'] = {'1': a, '2': b}
    return {'mode': 'formal' if formal else 'exploratory', 'pairsPerScenario': pairs,
            'decision': ('incomplete_keep_2' if missing else ('select_1' if failures else 'select_2')) if formal else 'exploratory_keep_2',
            'missing': sorted(set(missing)), 'failedThresholds': sorted(set(failures)), 'scenarios': scenes, 'samples': samples}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--log', action='append', required=True, type=pathlib.Path)
    parser.add_argument('--metrics', action='append', default=[], type=pathlib.Path)
    parser.add_argument('--hitches', type=pathlib.Path, help='Reviewed trace rows; never invent unavailable metrics')
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--pairs', type=int, default=20, help='Small samples report trends without declaring a winner')
    parser.add_argument('--scene', action='append', choices=SCENES)
    args = parser.parse_args()
    metric_rows = [row for path in args.metrics for row in json.loads(path.read_text())]
    if args.pairs < 1: parser.error('--pairs must be positive')
    report = summarize([p.read_text() for p in args.log], metric_rows, json.loads(args.hitches.read_text()) if args.hitches else [], pairs=args.pairs, selected_scenes=args.scene)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(report['decision'])
    for item in report['missing']: print('MISSING:', item)
    for item in report['failedThresholds']: print('THRESHOLD:', item)
