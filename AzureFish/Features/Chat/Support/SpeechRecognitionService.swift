//
//  SpeechRecognitionService.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 将实时麦克风输入转换为文本草稿的对象。
@MainActor
protocol SpeechTranscribing: AnyObject {
    /// 开始按照指定区域设置转写麦克风输入。
    ///
    /// - Parameters:
    ///   - locale: 决定识别语言的区域设置。
    ///   - result: 识别结果变化时调用的闭包，参数为当前转写文本及其是否为最终结果。
    ///   - failure: 识别因错误终止时调用的闭包。
    func start(
        locale: Locale,
        result: @escaping @MainActor (String, Bool) -> Void,
        failure: @escaping @MainActor () -> Void
    ) async throws

    /// 停止当前转写并释放其音频输入。
    func stop()
}

/// iMessage 聊天 Demo 使用的系统语音识别器。
///
/// 在 iOS 26 及更高版本中，此对象优先使用 `SpeechAnalyzer`，并安装
/// `SpeechTranscriber` 所需资源。Analyzer 启动阶段不可用时会降级到
/// `SFSpeechRecognizer`；两个后端均不可用时才把启动错误返回给调用方。旧版实现
/// 同时为未来降低 Demo 部署目标而保留，并在支持时优先采用设备端识别。
@available(iOS 26.0, *)
@MainActor
final class SpeechRecognitionService: SpeechTranscribing {

    /// 调用方显式选择的语音后端；为 `nil` 时根据系统能力自动选择。
    private let requestedBackend: SpeechBackend?
    /// 标识当前启动请求，使停止或重新启动前的异步工作失效。
    private let recognitionScope = OperationScope()
    /// 向识别请求或分析器提供麦克风输入的音频引擎。
    private var audioEngine: AVAudioEngine?
    /// 兼容后端当前接收音频缓冲区的识别请求。
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    /// 兼容后端当前的系统识别任务。
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 向现代分析器传递输入音频的异步任务。
    private var analysisTask: Task<Void, Never>?
    /// 消费现代语音识别结果序列的异步任务。
    private var resultsTask: Task<Void, Never>?
    /// 当前现代语音分析器；停止时取消分析并释放。
    private var analyzer: SpeechAnalyzer?
    /// 现代后端已确认的完整识别文本。
    private var stableModernTranscript = ""
    /// 现代后端尚未确认的当前识别片段。
    private var partialModernTranscript = ""
    /// 拼接识别片段使用的分隔符；中文使用空字符串。
    private var modernTranscriptSeparator = " "

    /// 创建系统语音识别服务。
    ///
    /// - Parameter backend: 能力测试使用的后端覆盖值。传入 `nil` 可为当前运行系统
    ///   选择最佳后端。
    init(backend: SpeechBackend? = nil) {
        requestedBackend = backend
    }

    /// 停止旧会话并启动指定语言的实时识别。
    ///
    /// 自动选择现代后端且启动失败时可回退到兼容后端；显式指定时保留其失败结果。
    func start(
        locale: Locale,
        result: @escaping @MainActor (String, Bool) -> Void,
        failure: @escaping @MainActor () -> Void
    ) async throws {
        stop()
        try Task.checkCancellation()
        let operation = recognitionScope.begin()
        var didStart = false
        defer {
            if !didStart, operation.isCurrent { stop() }
        }
        let backend = requestedBackend ?? .speechAnalyzer

        if backend == .speechAnalyzer {
            do {
                try await startModern(
                    operation: operation,
                    locale: locale,
                    result: result,
                    failure: failure
                )
                didStart = true
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try operation.checkCancellation()
                guard SpeechConfiguration.fallbackBackend(
                    afterFailureOf: backend,
                    wasExplicitlyRequested: requestedBackend != nil
                ) == .speechRecognizer else {
                    throw error
                }
                releaseResources()
                try startLegacy(
                    operation: operation,
                    locale: locale,
                    result: result,
                    failure: failure
                )
                didStart = true
                return
            }
        }
        try startLegacy(
            operation: operation,
            locale: locale,
            result: result,
            failure: failure
        )
        didStart = true
    }

    /// 停止音频输入并取消两种后端的任务，清空累计识别文本。
    func stop() {
        recognitionScope.invalidate()
        releaseResources()
    }

    /// 清理后端资源；自动回退时保留当前启动请求的标识。
    private func releaseResources() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
        analysisTask?.cancel()
        resultsTask?.cancel()
        analysisTask = nil
        resultsTask = nil
        stableModernTranscript = ""
        partialModernTranscript = ""
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil
    }

    /// 准备语言资源与现代分析器，将麦克风缓冲区输入识别流程并发布文本更新。
    private func startModern(
        operation: OperationScope.Token,
        locale: Locale,
        result: @escaping @MainActor (String, Bool) -> Void,
        failure: @escaping @MainActor () -> Void
    ) async throws {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: locale
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        try operation.checkCancellation()
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        modernTranscriptSeparator = (
            supportedLocale.language.languageCode?.identifier == "zh"
        ) ? "" : " "
        let installationRequest = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber])
        try operation.checkCancellation()
        if let installationRequest {
            try await installationRequest.downloadAndInstall()
            try operation.checkCancellation()
        }

        let engine = AVAudioEngine()
        let naturalFormat = try validatedInputFormat(of: engine)
        guard let analyzerFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: naturalFormat
            ) else {
            throw CocoaError(.featureUnsupported)
        }
        try operation.checkCancellation()
        // 格式选择期间路由可能变化；直接挂在输入节点的 tap 必须匹配硬件采样率。
        let currentFormat = try validatedInputFormat(of: engine)
        try SpeechInputFormat.validate(analyzerFormat)
        guard currentFormat == naturalFormat,
              analyzerFormat.sampleRate == currentFormat.sampleRate,
              analyzerFormat.channelCount == currentFormat.channelCount else {
            throw CocoaError(.featureUnsupported)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: analyzerFormat,
            block: SpeechRecognitionCallbacks.modernAudioTap(continuation: continuation)
        )
        audioEngine = engine
        engine.prepare()
        try engine.start()

        resultsTask = Task {
            do {
                for try await transcription in transcriber.results {
                    guard !Task.isCancelled, operation.isCurrent else { return }
                    let text = String(transcription.text.characters)
                    if transcription.isFinal {
                        stableModernTranscript = joinedTranscript(
                            stableModernTranscript,
                            text
                        )
                        partialModernTranscript = ""
                    } else {
                        partialModernTranscript = text
                    }
                    result(
                        joinedTranscript(
                            stableModernTranscript,
                            partialModernTranscript
                        ),
                        false
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard operation.isCurrent else { return }
                failure()
            }
        }
        analysisTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(stream)
            } catch is CancellationError {
                return
            } catch {
                guard operation.isCurrent else { return }
                failure()
            }
        }
    }

    /// 创建兼容识别器和麦克风缓冲区请求，并发布部分与最终识别结果。
    private func startLegacy(
        operation: OperationScope.Token,
        locale: Locale,
        result: @escaping @MainActor (String, Bool) -> Void,
        failure: @escaping @MainActor () -> Void
    ) throws {
        try operation.checkCancellation()
        let engine = AVAudioEngine()
        let format = try validatedInputFormat(of: engine)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw CocoaError(.featureUnsupported)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer
            .supportsOnDeviceRecognition

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: SpeechRecognitionCallbacks.legacyAudioTap(request: request)
        )
        recognitionRequest = request
        audioEngine = engine
        recognitionTask = recognizer.recognitionTask(
            with: request,
            resultHandler: SpeechRecognitionCallbacks.legacyResultHandler(
                operation: operation,
                result: result,
                failure: failure
            )
        )
        engine.prepare()
        try engine.start()
    }

    /// 同时验证硬件输入与 tap 输出，避免把无输入路由的零格式交给 AVFAudio。
    private func validatedInputFormat(of engine: AVAudioEngine) throws -> AVAudioFormat {
        let input = engine.inputNode
        try SpeechInputFormat.validate(input.inputFormat(forBus: 0))
        let format = input.outputFormat(forBus: 0)
        try SpeechInputFormat.validate(format)
        return format
    }

    /// 按当前语言的分隔规则拼接已确认文本和当前片段。
    private func joinedTranscript(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        return prefix + modernTranscriptSeparator + suffix
    }
}

/// 系统可从任意队列调用这些闭包；创建时不能继承服务的 MainActor 隔离。
enum SpeechRecognitionCallbacks {
    /// 在音频回调内同步提交缓冲区，避免将实时音频工作调度到主 Actor。
    nonisolated static func legacyAudioTap(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    /// 现代后端同样使用非隔离的 tap，通过线程安全的 continuation 传递输入。
    @available(iOS 26.0, *)
    nonisolated static func modernAudioTap(
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in continuation.yield(AnalyzerInput(buffer: buffer)) }
    }

    /// 先提取值类型结果，再回到主 Actor 验证会话并更新调用方。
    nonisolated static func legacyResultHandler(
        operation: OperationScope.Token,
        result: @escaping @MainActor (String, Bool) -> Void,
        failure: @escaping @MainActor () -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { recognitionResult, error in
            let text = recognitionResult?.bestTranscription.formattedString
            let isFinal = recognitionResult?.isFinal ?? false
            let didFail = error != nil
            Task { @MainActor in
                guard operation.isCurrent else { return }
                if let text { result(text, isFinal) }
                // result 可能同步停止或替换当前会话。
                if didFail, operation.isCurrent { failure() }
            }
        }
    }
}

/// 检查录音格式能否用于 tap；无效格式必须在进入系统断言前作为启动错误返回。
enum SpeechInputFormat {
    /// 硬件尚未提供有效的采样率或声道数。
    enum ValidationError: Error {
        /// 当前输入格式无法录音。
        case unavailable
    }

    /// 拒绝零采样率、非有限采样率及无声道输入，不使用虚构格式替代硬件状态。
    static func validate(_ format: AVAudioFormat) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0 else {
            throw ValidationError.unavailable
        }
    }
}
