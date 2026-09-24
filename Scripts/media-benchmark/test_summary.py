"""Synthetic tests for evidence completeness and parameter selection, not performance measurements."""
import json
import unittest
from summarize import summarize, p90, SCENES

class SummaryTests(unittest.TestCase):
    def fixture(self):
        rows, metrics, hitches = [], [], []
        for scene, method in SCENES.items():
            for sample in range(40):
                pair = sample // 2
                first = 1 if pair % 2 == 0 else 2
                limit = first if sample % 2 == 0 else 3 - first
                rows.append(dict(scenario=scene, pair=pair, sample=sample, limit=limit, measured=True,
                    allReadyMs=1000 if limit == 1 else 800, firstReadyMs=100,
                    originals=[dict(milliseconds=100)], memoryWarnings=0, remainingFiles=0,
                    thermalInvalid=False, lowPowerInvalid=False, overlappingScrollSteps=2, physicalDevice=True, previewOverlappedImport=True))
                hitches.append(dict(scenario=scene, pair=pair, limit=limit, ratioMsPerSecond=1,
                    newMediaStallOver100ms=False, evidence='synthetic-test-only'))
            metrics.append(dict(testIdentifier=f'Tests/{method}()', testRuns=[dict(metrics=[dict(
                identifier='com.apple.dt.XCTMetric_Memory.physical_peak', unitOfMeasurement='kB', measurements=[100000] * 40)])]))
        return rows, metrics, hitches

    def run_report(self, rows, metrics, hitches):
        return summarize(['\n'.join('MEDIA_AB_SAMPLE ' + json.dumps(r) for r in rows)], metrics, hitches)

    def test_complete_evidence_can_select_two(self):
        self.assertEqual(self.run_report(*self.fixture())['decision'], 'select_2')

    def test_missing_hitch_evidence_cannot_select_winner(self):
        rows, metrics, _ = self.fixture()
        self.assertEqual(self.run_report(rows, metrics, [])['decision'], 'incomplete_keep_2')

    def test_complete_regression_selects_one(self):
        rows, metrics, hitches = self.fixture()
        metrics[0]['testRuns'][0]['metrics'][0]['measurements'] = [100000 if r['limit'] == 1 else 130000 for r in rows[:40]]
        self.assertEqual(self.run_report(rows, metrics, hitches)['decision'], 'select_1')

    def test_missing_and_duplicate_samples_are_incomplete(self):
        rows, metrics, hitches = self.fixture()
        rows[0] = rows[1]
        self.assertEqual(self.run_report(rows, metrics, hitches)['decision'], 'incomplete_keep_2')

    def test_simulator_cannot_select_winner(self):
        rows, metrics, hitches = self.fixture()
        for row in rows: row['physicalDevice'] = False
        self.assertEqual(self.run_report(rows, metrics, hitches)['decision'], 'incomplete_keep_2')

    def test_nearest_rank_p90(self):
        self.assertEqual(p90(list(range(1, 21))), 18)

    def test_small_daily_sample_reports_trends_without_formal_winner(self):
        rows, metrics, hitches = self.fixture()
        rows = rows[:6]
        metrics = metrics[:1]
        metrics[0]['testRuns'][0]['metrics'][0]['measurements'] = [100000] * 6
        report = summarize(['\n'.join('MEDIA_AB_SAMPLE ' + json.dumps(r) for r in rows)], metrics, hitches[:6], pairs=3, selected_scenes=['cold'])
        self.assertEqual(report['decision'], 'exploratory_keep_2')
        self.assertEqual(report['scenarios']['cold']['bFasterPairs'], 3)
        self.assertEqual(report['missing'], [])

    def test_distribution_statistics_keep_native_hitches_without_attribution(self):
        rows, metrics, _ = self.fixture()
        metrics[0]['testRuns'][0]['metrics'].extend([
            dict(identifier='com.apple.dt.XCTMetric_CPU-Demo.time', unitOfMeasurement='s', measurements=[2] * 40),
            dict(identifier='com.apple.dt.XCTMetric_Hitch-Demo.time.ratio', unitOfMeasurement='ms per s', measurements=[0] * 40),
        ])
        report = self.run_report(rows, metrics, [])
        self.assertEqual(report['decision'], 'incomplete_keep_2')
        result = report['scenarios']['cold']['1']
        self.assertEqual(result['firstReadyP90Ms'], 100)
        self.assertEqual(result['peakMemoryP90MB'], 100)
        self.assertEqual(result['cpuP90Seconds'], 2)
        self.assertEqual(result['hitchRatioP90MsPerSecond'], 0)

if __name__ == '__main__': unittest.main()
