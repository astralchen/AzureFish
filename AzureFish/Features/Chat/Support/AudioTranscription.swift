import AVFAudio
import Foundation
import Speech

/// 读取已提交的音频文件。实现不得启动麦克风或更改播放音频会话。
@MainActor
protocol AudioFileTranscribing: AnyObject {
    /// 识别指定本地音频文件的完整文本。
    ///
    /// - Parameters:
    ///   - fileURL: 已提交且可读的音频文件 URL。
    ///   - locale: 决定识别语言的区域设置。
    /// - Returns: 完整转写文本；未取得结果时为 `nil`。
    /// - Throws: 识别、文件读取或任务取消产生的错误。
    func transcribe(fileURL: URL, locale: Locale) async throws -> String?
}

/// 页面内的串行识别队列。结果与消息、附件双重身份绑定，失败也记为已尝试。
@available(iOS 16.0, *)
@MainActor
final class AudioTranscriptionCoordinator {
    /// 以消息和附件双重身份区分一次文件转写请求的键。
    private struct Key: Hashable {
        /// 待回填识别文本的消息标识符。
        let messageID: Int
        /// 待识别音频附件的稳定标识符。
        let attachmentID: UUID
    }

    /// 在串行队列中等待识别的文件及语言快照。
    private struct Job {
        /// 绑定消息与音频附件身份的请求键。
        let key: Key
        /// 等待转写的已提交音频文件 URL。
        let fileURL: URL
        /// 请求入队时捕获的识别区域设置。
        let locale: Locale
    }

    /// 执行完整音频文件识别的服务。
    private let transcriber: any AudioFileTranscribing
    /// 有效识别结果到达时调用的闭包，依次传入消息身份、附件身份和文本。
    private let completion: (Int, UUID, String) -> Void
    /// 已经受理的请求身份集合；包括失败请求，避免自动重复识别。
    private var attempted: Set<Key> = []
    /// 按时间线发现顺序等待处理的转写请求。
    private var queue: [Job] = []
    /// 串行消费转写队列的任务；空闲时为 `nil`。
    private var worker: Task<Void, Never>?
    /// 指示页面已退出、不得再受理或回填结果的布尔值。
    private var invalidated = false

    /// 创建串行转写协调器，并指定文件识别服务及结果回调。
    init(
        transcriber: any AudioFileTranscribing,
        completion: @escaping (Int, UUID, String) -> Void
    ) {
        self.transcriber = transcriber
        self.completion = completion
    }

    /// 在协调器释放时取消尚未完成的队列任务。
    deinit { worker?.cancel() }

    /// 将时间线中尚无转写文本的音频按双重身份去重入队，并启动单个工作任务。
    func enqueue(_ state: ChatViewModel.State, locale: Locale) {
        guard !invalidated else { return }
        for item in state.timeline {
            guard case .message(let message) = item.content,
                  let audio = message.audio, audio.transcript == nil else { continue }
            let key = Key(messageID: message.id, attachmentID: audio.id)
            // 入队即占用身份；重复渲染、识别失败和空结果都不会自动发起第二次请求。
            guard attempted.insert(key).inserted else { continue }
            queue.append(Job(key: key, fileURL: audio.fileURL, locale: locale))
        }
        guard worker == nil, !queue.isEmpty else { return }
        // Task 不会在同步发送调用栈内执行；录音草稿先完成提交、退出预览。
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let job = self?.takeNext() else { break }
                guard let transcriber = self?.transcriber else { break }
                do {
                    let result = try await transcriber.transcribe(fileURL: job.fileURL, locale: job.locale)
                    guard !Task.isCancelled, self?.invalidated == false else { break }
                    if let text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        self?.completion(job.key.messageID, job.key.attachmentID, text)
                    }
                } catch {
                    // 识别是可选增强；失败不改变已发送消息，也不重复请求。
                }
            }
            self?.worker = nil
        }
    }

    /// 永久停止队列，取消当前任务并忽略之后到达的识别结果。
    func cancelAll() {
        invalidated = true
        queue.removeAll()
        worker?.cancel()
        worker = nil
    }

    /// 取出最早入队的请求；队列为空或已失效时返回 `nil`。
    private func takeNext() -> Job? {
        guard !invalidated, !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}

/// 文件识别使用独立的系统请求，与输入栏的实时转写互不取消。
@available(iOS 26.0, *)
@MainActor
final class AudioFileTranscriber: AudioFileTranscribing {
    /// 显式指定的识别后端；为 `nil` 时使用系统能力选择与启动回退策略。
    private let requestedBackend: SpeechBackend?
    /// 兼容文件识别后端使用的语音权限提供者。
    private let permissionProvider: any MediaPermissionProviding

    /// 创建文件转写器，并允许指定识别后端和权限提供者。
    init(
        backend: SpeechBackend? = nil,
        permissionProvider: (any MediaPermissionProviding)? = nil
    ) {
        requestedBackend = backend
        self.permissionProvider = permissionProvider ?? SystemPermissionProvider()
    }

    /// 选择识别后端并转写本地文件。
    ///
    /// 只有自动选中的现代后端准备失败时回退；运行错误和取消不会重新启动其他后端。
    func transcribe(fileURL: URL, locale: Locale) async throws -> String? {
        try Task.checkCancellation()
        let backend = requestedBackend ?? .speechAnalyzer
        if backend == .speechAnalyzer {
            let prepared: (SpeechAnalyzer, SpeechTranscriber, AVAudioFile)
            do {
                prepared = try await prepareModern(fileURL: fileURL, locale: locale)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                guard SpeechConfiguration.fallbackBackend(
                    afterFailureOf: backend, wasExplicitlyRequested: requestedBackend != nil
                ) != nil else { throw error }
                return try await transcribeLegacy(fileURL: fileURL, locale: locale)
            }
            // 成功准备后发生的运行错误不重启另一个后端。
            return try await runModern(prepared, locale: locale)
        }
        return try await transcribeLegacy(fileURL: fileURL, locale: locale)
    }

    /// 预留并安装目标语言资源，打开文件并准备现代分析器。
    ///
    /// 准备失败或取消时结束分析器，然后向调用方抛出错误。
    private func prepareModern(fileURL: URL, locale: Locale) async throws -> (SpeechAnalyzer, SpeechTranscriber, AVAudioFile) {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CocoaError(.featureUnsupported)
        }
        try Task.checkCancellation()
        // 在请求模型安装前明确预留语言，避免新安装的 App 尚未订阅该语言资源。
        try await AssetInventory.reserve(locale: supported)
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.prepareToAnalyze(in: file.processingFormat)
            try Task.checkCancellation()
            return (analyzer, transcriber, file)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// 运行已准备的文件分析器，收集最终文本片段并按语言规则拼接。
    ///
    /// 取消或失败时同时终止结果任务与分析器。
    private func runModern(_ prepared: (SpeechAnalyzer, SpeechTranscriber, AVAudioFile), locale: Locale) async throws -> String? {
        let (analyzer, transcriber, file) = prepared
        return try await withTaskCancellationHandler {
            let results = Task { () throws -> String in
                var segments: [String] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    if result.isFinal { segments.append(String(result.text.characters)) }
                }
                return segments.joined(separator: locale.language.languageCode?.identifier == "zh" ? "" : " ")
            }
            do {
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let text = try await results.value
                try Task.checkCancellation()
                return text
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// 请求语音识别权限，优先尝试设备端识别，再按错误情况尝试系统在线识别。
    ///
    /// 权限或识别器不可用时返回 `nil`；取消不会触发在线回退。
    private func transcribeLegacy(fileURL: URL, locale: Locale) async throws -> String? {
        let authorized = await permissionProvider.requestSpeechPermission()
        try Task.checkCancellation()
        guard authorized, let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return nil
        }
        if recognizer.supportsOnDeviceRecognition {
            do {
                return try await LegacyFileRequest().run(recognizer: recognizer, fileURL: fileURL, onDevice: true)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
            }
        }
        return try await LegacyFileRequest().run(recognizer: recognizer, fileURL: fileURL, onDevice: false)
    }
}

/// 单个请求拥有自己的 continuation；取消和迟到的回调都只能完成一次。
@available(iOS 16.0, *)
@MainActor
private final class LegacyFileRequest {
    /// 当前文件识别的系统任务。
    private var task: SFSpeechRecognitionTask?
    /// 等待最终文本或错误的延续；清空后不再受理迟到回调。
    private var continuation: CheckedContinuation<String?, any Error>?

    /// 执行一次兼容文件识别，并将任务取消转换为唯一的结束结果。
    ///
    /// `onDevice` 决定是否要求设备端识别；只受理最终文本。
    func run(recognizer: SFSpeechRecognizer, fileURL: URL, onDevice: Bool) async throws -> String? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let request = SFSpeechURLRecognitionRequest(url: fileURL)
                request.shouldReportPartialResults = false
                request.requiresOnDeviceRecognition = onDevice
                request.addsPunctuation = true
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                    Task { @MainActor [weak self] in
                        if let text { self?.finish(.success(text)) }
                        else if let error { self?.finish(.failure(error)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    /// 先解除请求与延续的持有，再取消系统任务并一次性恢复调用方。
    private func finish(_ result: Result<String?, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let task = task
        self.task = nil
        task?.cancel()
        continuation.resume(with: result)
    }
}
