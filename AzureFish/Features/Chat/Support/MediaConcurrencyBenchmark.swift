#if MEDIA_BENCHMARK
import CryptoKit
import Foundation
import os
import UIKit
import UniformTypeIdentifiers

/// 仅专用性能构建编译的真机驱动；本地 provider 经过生产导入队列，不模拟 iCloud。
@available(iOS 26.0, *)
@MainActor
final class MediaConcurrencyBenchmark {
    /// 驱动不延长聊天页面生命周期。
    private weak var chat: ChatViewController?
    /// 测量状态和 JSON 结果通过测试按钮的辅助功能值交给 XCTest。
    private let button = UIButton(type: .system)
    /// 本次场景；正常构建不存在此入口。
    private let scenario: String
    /// 哈希验证后的固定原件清单，重复来源仍有独立的导入身份。
    private var sources: [URL] = []
    /// 页面退出后取消等待和交互脚本。
    private(set) var task: Task<Void, Never>?
    /// 全部占位完成登记后的单调时钟起点。
    private var importStart: CFTimeInterval = 0
    /// 首个可预览条目实际发布的时间。
    private var firstReady: Double?
    /// 全部 20 项实际发布完成的时间。
    private var allReady: Double?
    /// 当前原图从打开或切页请求起计算，取消请求不计成功。
    private var originalStart: CFTimeInterval?
    /// 每次成功设置完整原图的时间和像素尺寸。
    private var originalSamples: [[String: Double]] = []
    /// 导入时的原始顺序，用于验收而非排序修复。
    private var orderedIDs: [UUID] = []
    /// 内存警告累计数量；任何一次都令本样本无效。
    private var memoryWarnings = 0
    /// 测量期间是否经历非正常热状态。
    private var thermalInvalid = false
    /// 测量期间是否开启低电量模式。
    private var lowPowerInvalid = false
    /// 观察系统内存警告的令牌。
    private var observer: NSObjectProtocol?
    /// 导入中实际执行的滚动步骤数，防止把导入后滚动误算成竞争场景。
    private var overlappingScrollSteps = 0
    /// 打开首张预览时是否仍有导入，防止测试退化为完成后的预览。
    private var previewOverlappedImport = false
    /// 测量环境的原始亮度，离开时恢复。
    private let previousBrightness: CGFloat

    /// 从启动参数读取四种固定负载；单元测试可覆盖场景以验证准备期间的取消。
    init(chat: ChatViewController, scenarioOverride: String? = nil) {
        self.chat = chat
        let args = ProcessInfo.processInfo.arguments
        if let scenarioOverride { scenario = scenarioOverride }
        else if let index = args.firstIndex(of: "-media-benchmark"), args.indices.contains(index + 1) { scenario = args[index + 1] }
        else { scenario = "cold" }
        previousBrightness = UIScreen.main.brightness
    }

    /// 安装测试专用按钮；准备与哈希验证发生在计时之前。
    func install() {
        guard let chat else { return }
        button.setTitle("Benchmark", for: .normal)
        button.accessibilityIdentifier = "media.benchmark.start"
        button.accessibilityValue = "preparing"
        button.addAction(UIAction { [weak self] _ in self?.start() }, for: .touchUpInside)
        chat.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: button)
        chat.photoController.benchmarkDidPublish = { [weak self] in self?.published() }
        chat.mediaImageLoader.benchmarkOriginalDisplayed = { [weak self] _, size in
            guard let self, let start = originalStart else { return }
            originalSamples.append(["milliseconds": (CACurrentMediaTime() - start) * 1000,
                                    "width": size.width, "height": size.height])
            originalStart = nil
        }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.memoryWarnings += 1 } }
        UIScreen.main.brightness = 0.5
        task = Task { [weak self] in
            guard let self else { return }
            do {
                sources = try await Self.checkedSources()
                try Task.checkCancellation()
                if scenario == "warm" { beginImport(); try await wait { self.allReady != nil } }
                try await wait(timeout: 300) { ProcessInfo.processInfo.thermalState == .nominal && !ProcessInfo.processInfo.isLowPowerModeEnabled }
                button.accessibilityValue = "ready"
            } catch is CancellationError {
                // 页面退出不发布失败或迟到的就绪状态。
            } catch { fail(error) }
        }
    }

    /// 页面实际退出时立即取消；先解除回调，防止后台资源校验完成后重新开始导入。
    func cancel() {
        task?.cancel()
        task = nil
        chat?.photoController.benchmarkDidPublish = nil
        chat?.mediaImageLoader.benchmarkOriginalDisplayed = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIScreen.main.brightness = previousBrightness
    }

    /// 开始正式场景；异步轮询仅等待状态，时间来自实际发布和原图设置回调。
    private func start() {
        guard button.accessibilityValue == "ready" else { return }
        button.accessibilityValue = "running"
        thermalInvalid = false
        lowPowerInvalid = false
        memoryWarnings = 0
        task = Task { [weak self] in
            guard let self, let chat else { return }
            let interval = MediaPerformance.signposter.beginInterval("MediaBenchmarkScenario", id: MediaPerformance.signposter.makeSignpostID())
            defer { MediaPerformance.signposter.endInterval("MediaBenchmarkScenario", interval) }
            do {
                try Task.checkCancellation()
                if scenario != "warm" { beginImport() }
                switch scenario {
                case "preview":
                    try await wait { self.firstReady != nil }
                    previewOverlappedImport = allReady == nil && !chat.photoController.activeImports.isEmpty
                    let first = try require(chat.photoController.entries.first?.presentation.mediaItem)
                    try await preview(.init(id: try require(chat.photoController.draft?.groupID), items: [first]))
                case "scroll":
                    for step in 0..<12 {
                        if allReady == nil { overlappingScrollSteps += 1 }
                        let strip = chat.composerView.mediaDraftStripView.scrollView
                        let list = chat.conversationView.collectionView
                        strip.setContentOffset(CGPoint(x: step.isMultiple(of: 2) ? max(0, strip.contentSize.width - strip.bounds.width) : 0, y: 0), animated: true)
                        list.setContentOffset(CGPoint(x: 0, y: step.isMultiple(of: 2) ? -list.adjustedContentInset.top : max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height)), animated: true)
                        try await Task.sleep(for: .milliseconds(250))
                    }
                case "warm":
                    let group = try require(chat.photoController.draftAttachment)
                    for _ in 0..<3 { try await preview(group, page: true) }
                default: break
                }
                try await wait { self.allReady != nil && chat.photoController.activeImports.isEmpty }
                try await wait { chat.mediaImageLoader.scheduler.activeCount == 0 && chat.mediaImageLoader.scheduler.waitingCount == 0 }
                guard chat.photoController.entries.map(\.id) == orderedIDs,
                      chat.photoController.draftAttachment?.items.count == 20 else { throw Failure.invalidOrder }
                if let store = chat.attachmentStore as? PageAttachmentStore {
                    let files = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)
                    guard files.count == 40 else { throw Failure.invalidFiles }
                }
                sampleEnvironment()
                var report: [String: Any] = ["scenario": scenario, "limit": MediaWorkScheduler.pageLimit,
                    "firstReadyMs": firstReady ?? -1, "allReadyMs": allReady ?? -1, "originals": originalSamples,
                    "memoryWarnings": memoryWarnings, "thermalInvalid": thermalInvalid, "lowPowerInvalid": lowPowerInvalid,
                    "overlappingScrollSteps": overlappingScrollSteps, "previewOverlappedImport": previewOverlappedImport, "brightness": UIScreen.main.brightness,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString, "physicalDevice": Self.isPhysicalDevice, "status": "complete"]
                // 文件清理纳入有效性判定，但不计入导入计时。
                chat.photoController.discardDraft()
                if let store = chat.attachmentStore as? PageAttachmentStore {
                    report["remainingFiles"] = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil).count
                }
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                UIScreen.main.brightness = previousBrightness
                button.accessibilityValue = String(decoding: data, as: UTF8.self)
            } catch is CancellationError {
                // 正常离开由页面回收文件，不能继续写测试结果。
            } catch { fail(error) }
        }
    }

    /// 先登记 20 个占位，再启动真实系统提供者队列；原件由 provider 回调同步交给复制状态机。
    private func beginImport() {
        guard let chat else { return }
        let controller = chat.photoController
        for (index, source) in sources.enumerated() {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.image.identifier, fileOptions: [], visibility: .all) { completion in
                completion(source, false, nil)
                return nil
            }
            let entry = PhotoPickerController.DraftEntry(assetIdentifier: "benchmark-\(index)")
            controller.entries.append(entry)
            controller.pendingImports.append(.init(provider: provider, entry: entry, generation: controller.generation))
        }
        orderedIDs = controller.entries.map(\.id)
        controller.publishDraft()
        importStart = CACurrentMediaTime()
        controller.drainImports()
    }

    /// 在生产草稿发布完成的同一主 actor 调用栈内打点。
    private func published() {
        guard importStart > 0, let controller = chat?.photoController else { return }
        let elapsed = (CACurrentMediaTime() - importStart) * 1000
        if firstReady == nil, controller.entries.first?.presentation.mediaItem != nil { firstReady = elapsed }
        if allReady == nil, controller.draftAttachment?.items.count == 20 { allReady = elapsed }
        sampleEnvironment()
    }

    /// 打开真实预览器并等待原图实际设置；快速切页走预览器既有的选择路径。
    private func preview(_ group: MediaGroupAttachment, page: Bool = false) async throws {
        guard let chat else { throw CancellationError() }
        let count = originalSamples.count
        originalStart = CACurrentMediaTime()
        chat.openAttachmentPreview(.init(attachment: .mediaGroup(group), initialIndex: 0, source: .photoDraft(group.id)))
        try await wait { self.originalSamples.count > count }
        try await Task.sleep(for: .milliseconds(500))
        if page, let controller = chat.attachmentPreviewController as? AttachmentPreviewController {
            for index in [1, 2, 3] {
                originalStart = nil
                controller.select(index, animated: true)
                try await Task.sleep(for: .milliseconds(80))
            }
            let count = originalSamples.count
            originalStart = CACurrentMediaTime()
            controller.select(4, animated: true)
            try await wait { self.originalSamples.count > count }
            try await Task.sleep(for: .milliseconds(400))
        }
        (chat.attachmentPreviewController as? AttachmentPreviewController)?.closeTapped()
        try await wait { chat.attachmentPreviewController == nil && chat.presentedViewController == nil }
    }

    /// 在每次异步等待期间采样环境；热降频或低电量状态不会被遗漏为有效样本。
    private func sampleEnvironment() {
        thermalInvalid = thermalInvalid || ProcessInfo.processInfo.thermalState != .nominal
        lowPowerInvalid = lowPowerInvalid || ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    /// 有限等待，退出和取消传播到整个测试驱动。
    private func wait(timeout: Double = 60, _ condition: () -> Bool) async throws {
        try Task.checkCancellation()
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            try Task.checkCancellation()
            guard chat != nil, CACurrentMediaTime() < deadline else { throw Failure.timeout }
            sampleEnvironment()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }
    /// 将缺失的场景状态转换为可诊断的测试失败。
    private func require<T>(_ value: T?) throws -> T { guard let value else { throw Failure.missingState }; return value }
    /// 失败不发布成功样本，XCTest 会保存错误并终止本组。
    private func fail(_ error: Error) { UIScreen.main.brightness = previousBrightness; button.accessibilityValue = "error: \(error)" }
    /// 测试驱动错误不作为正常业务提示显示。
    private enum Failure: Error { case timeout, missingState, invalidOrder, invalidFiles, invalidManifest }

    /// 汇总器必须识别模拟器样本，不能将其用于选择真机默认值。
    nonisolated private static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// 在后台验证清单和 SHA-256；该读取不进入正式计时区间。
    @concurrent private static func checkedSources() async throws -> [URL] {
        guard let directory = Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle") else { throw Failure.invalidManifest }
        let data = try Data(contentsOf: directory.appendingPathComponent("benchmark-manifest.json"))
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], entries.count == 20 else { throw Failure.invalidManifest }
        return try entries.enumerated().map { index, entry in
            try Task.checkCancellation()
            guard entry["index"] as? Int == index, let file = entry["file"] as? String, !file.contains("/"),
                  let expected = entry["sha256"] as? String else { throw Failure.invalidManifest }
            let url = directory.appendingPathComponent(file)
            let actual = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw Failure.invalidManifest }
            return url
        }
    }
    /// 页面释放取消脚本并解除系统观察；不改动设备的低电量模式。
    isolated deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        UIScreen.main.brightness = previousBrightness
    }
}
#endif
