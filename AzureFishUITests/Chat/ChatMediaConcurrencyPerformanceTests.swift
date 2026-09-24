import OSLog
import XCTest

private let logger = Logger(subsystem: "Demo.UITests", category: "ChatMediaConcurrencyPerformanceTests")

/// 专用 Release 性能构建的配对测试；常规测试运行不会自动启动长时间基准。
final class ChatMediaConcurrencyPerformanceTests: XCTestCase {
    /// 默认每种场景 20 对样本；快速检查可通过运行器环境变量缩小规模。
    private var pairs: Int { max(1, Int(ProcessInfo.processInfo.environment["MEDIA_BENCHMARK_PAIRS"] ?? "20") ?? 20) }
    /// 两组采用相同的进程外冷却间隔；等待发生在应用启动和正式计时之前。
    private var cooldown: TimeInterval { max(0, Double(ProcessInfo.processInfo.environment["MEDIA_BENCHMARK_COOLDOWN_SECONDS"] ?? "10") ?? 10) }
    /// 测试入口需要显式开启，避免污染普通回归时间。
    override func setUpWithError() throws {
        guard #available(iOS 26.0, *), ProcessInfo.processInfo.environment["MEDIA_BENCHMARK_RUN"] == "1" else {
            throw XCTSkip("Requires dedicated MEDIA_BENCHMARK build and MEDIA_BENCHMARK_RUN=1")
        }
        continueAfterFailure = false
    }
    /// 两组均预热，再使用 A→B、B→A 的交替顺序；XCTest 首次丢弃样本单独标记。
    @MainActor private func compare(_ scenario: String) {
        let app = XCUIApplication()
        for limit in [1, 2] {
            let button = prepare(app, scenario: scenario, limit: limit)
            button.tap()
            _ = result(button)
            app.terminate()
        }
        let options = XCTMeasureOptions()
        options.iterationCount = pairs * 2
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var invocation = -1
        var metrics: [any XCTMetric] = [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app),
            XCTOSSignpostMetric(subsystem: "com.quicklayout.demo", category: "MediaPipeline", name: "MediaBenchmarkScenario")]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            let sample = invocation
            invocation += 1
            let pair = max(0, sample) / 2
            let first = pair.isMultiple(of: 2) ? 1 : 2
            let limit = max(0, sample).isMultiple(of: 2) ? first : 3 - first
            let button = prepare(app, scenario: scenario, limit: limit)
            startMeasuring()
            button.tap()
            var report = result(button, validateImmediately: false)
            stopMeasuring()
            report["sample"] = sample
            report["pair"] = pair
            report["measured"] = sample >= 0
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "media-ab-\(scenario)-\(sample)-limit\(limit).json"
            attachment.lifetime = .keepAlways
            add(attachment)
            logger.notice("MEDIA_AB_SAMPLE \(String(decoding: data, as: UTF8.self), privacy: .public)")
            validate(report)
            app.terminate()
        }
    }
    /// 启动独立进程并等待资源校验及温度恢复；该阶段不计入正式测量。
    @MainActor private func prepare(_ app: XCUIApplication, scenario: String, limit: Int) -> XCUIElement {
        // 只阻塞 XCTest 运行器；被测应用尚未启动，不改变应用主线程或测量区间。
        Thread.sleep(forTimeInterval: cooldown)
        app.launchArguments = ["-media-benchmark", scenario, "-media-work-limit", String(limit),
            "-azurefish.locale.identifier", "zh-Hans"]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        route.tap()
        let button = app.buttons["media.benchmark.start"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "App must be built with MEDIA_BENCHMARK")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready' OR value BEGINSWITH 'error:'"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 320), .completed)
        XCTAssertEqual(button.value as? String, "ready")
        return button
    }
    /// 保存应用的精确阶段计时，并拒绝热状态、内存警告和清理失败样本。
    @MainActor private func result(_ button: XCUIElement, validateImmediately: Bool = true) -> [String: Any] {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH '{' OR value BEGINSWITH 'error:'"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 100), .completed)
        let value = button.value as? String ?? ""
        guard let data = value.data(using: .utf8), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Missing report: \(value)")
            return [:]
        }
        if validateImmediately { validate(report) }
        return report
    }
    /// 正式样本先保存原始 JSON 再检查有效性，热状态失败也必须留下可复核证据。
    @MainActor private func validate(_ report: [String: Any]) {
        XCTAssertEqual(report["memoryWarnings"] as? Int, 0)
        XCTAssertEqual(report["remainingFiles"] as? Int, 0)
        XCTAssertEqual(report["thermalInvalid"] as? Bool, false)
        XCTAssertEqual(report["lowPowerInvalid"] as? Bool, false)
        if report["scenario"] as? String == "preview" { XCTAssertEqual(report["previewOverlappedImport"] as? Bool, true) }
        if report["scenario"] as? String == "scroll" { XCTAssertGreaterThan(report["overlappingScrollSteps"] as? Int ?? 0, 0) }
        for sample in report["originals"] as? [[String: Double]] ?? [] {
            XCTAssertEqual(sample["width"], 4032)
            XCTAssertEqual(sample["height"], 3024)
        }
    }
    /// 无交互时 20 张全部就绪的吞吐量。
    @MainActor func testColdImport() { compare("cold") }
    /// 首张就绪即预览，原图读取与剩余导入竞争同一预算。
    @MainActor func testPreviewDuringImport() { compare("preview") }
    /// 导入期间执行固定节奏滚动，记录真实渲染卡顿。
    @MainActor func testScrollDuringImport() { compare("scroll") }
    /// 完成导入后重复打开、快速切页和关闭。
    @MainActor func testWarmPreview() { compare("warm") }
}
