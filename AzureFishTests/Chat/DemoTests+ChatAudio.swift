import AVFAudio
import CoreGraphics
import Testing
import UIKit
import AppLocalization
import QuickLayoutKit
@_spi(Testing) import QuickLayoutKitUIKit
@testable import AzureFish

extension DemoTests {

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func replyWaveformUsesDeterministicPCMAmplitude()
        throws {
        guard #available(iOS 26.0, *) else { return }
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 8_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)
        )
        buffer.frameLength = 512
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<256 {
            channel[frame] = 0.01
        }
        for frame in 256..<512 {
            channel[frame] = 1
        }

        let samples = AudioController.replyWaveformSamples(
            from: buffer
        )
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 0.1) < 0.0001)
        #expect(samples[1] == 1)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func recordingPolicyHonorsMinimumAndMaximumDurations() {
        guard #available(iOS 26.0, *) else { return }
        #expect(
            !RecordingPolicy.accepts(
                duration: 0.99,
                fileExists: true
            )
        )
        #expect(
            RecordingPolicy.accepts(
                duration: 1,
                fileExists: true
            )
        )
        #expect(
            !RecordingPolicy.accepts(
                duration: 1,
                fileExists: false
            )
        )
        #expect(!RecordingPolicy.shouldStop(elapsed: 119.99))
        #expect(RecordingPolicy.shouldStop(elapsed: 120))
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func attachmentStoreCommitsAndDiscardsTransactionally()
        throws {
        guard #available(iOS 26.0, *) else { return }
        let fileManager = FileManager.default
        let parentDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ChatStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: parentDirectory) }

        let store = PageAttachmentStore(
            fileManager: fileManager,
            parentDirectory: parentDirectory
        )
        let pickerURL = parentDirectory
            .appendingPathComponent("picker-source.jpg")
        try Data([7, 8, 9]).write(to: pickerURL)
        let importedURL = try store.importFile(
            at: pickerURL,
            prefix: "image",
            pathExtension: nil
        )
        #expect(importedURL.deletingLastPathComponent() == store.directoryURL)
        #expect(importedURL.pathExtension == "jpg")
        #expect(try Data(contentsOf: importedURL) == Data([7, 8, 9]))

        let discardedURL = store.makeFileURL(
            prefix: "discarded",
            pathExtension: "m4a"
        )
        try Data([0]).write(to: discardedURL)
        let discarded = AudioAttachment(
            fileURL: discardedURL,
            duration: 2,
            waveform: [0.5]
        )
        store.registerDraft(.audio(discarded))
        store.discardDraft(id: discarded.id)
        #expect(!fileManager.fileExists(atPath: discardedURL.path))

        let committedURL = store.makeFileURL(
            prefix: "committed",
            pathExtension: "m4a"
        )
        try Data([1]).write(to: committedURL)
        let committed = AudioAttachment(
            fileURL: committedURL,
            duration: 2,
            waveform: [0.6]
        )
        store.registerDraft(.audio(committed))
        #expect(store.commitDraft(id: committed.id))
        store.discardDraft(id: committed.id)
        #expect(fileManager.fileExists(atPath: committedURL.path))

        let directoryURL = store.directoryURL
        store.removeAll()
        #expect(!fileManager.fileExists(atPath: importedURL.path))
        #expect(!fileManager.fileExists(atPath: committedURL.path))
        #expect(!fileManager.fileExists(atPath: directoryURL.path))
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func recordingWaveformKeepsStableDisplaySlots() {
        guard #available(iOS 26.0, *) else { return }
        #expect(RecordingWaveform.displaySampleCount == 60)
        let empty = RecordingWaveform.displaySamples([])
        #expect(
            empty.count == RecordingWaveform.displaySampleCount
        )
        #expect(empty.allSatisfy { $0 == 0.08 })

        let firstSample = RecordingWaveform.displaySamples([0.7])
        #expect(firstSample.count == empty.count)
        #expect(firstSample.dropLast().allSatisfy { $0 == 0.08 })
        #expect(firstSample.last == 0.7)

        let source = (0..<72).map { Float($0) / 72 }
        let scrolled = RecordingWaveform.displaySamples(source)
        #expect(scrolled.count == empty.count)
        #expect(scrolled.first == source[12])
        #expect(scrolled.last == source[71])
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func dictationReplacesPartialResultsAndIgnoresStaleResults()
        async {
        guard #available(iOS 26.0, *) else { return }
        let transcriber = ControlledSpeechTranscriber()
        let permissions = ControlledMediaPermissions(
            microphoneGranted: true,
            speechGranted: true
        )
        let audioSession = RecordingAudioSession()
        let controller = AudioController(
            audioSession: audioSession,
            fileManager: .default,
            speechTranscriber: transcriber,
            permissionProvider: permissions
        )
        var states: [ComposerState] = []
        controller.stateDidChange = { states.append($0) }

        controller.startDictation(locale: Locale(identifier: "zh-Hans"))
        #expect(await waitForCondition { transcriber.startCount == 1 })
        #expect(transcriber.locale?.identifier == "zh-CN")
        #expect(audioSession.captureActivationCount == 1)

        transcriber.emit(text: "你", isFinal: false)
        #expect(controller.state == .dictating(text: "你"))
        transcriber.emit(text: "你好", isFinal: false)
        #expect(controller.state == .dictating(text: "你好"))

        controller.stopDictation()
        #expect(controller.state == .idle)
        #expect(transcriber.stopCount == 1)
        transcriber.emit(text: "不应覆盖", isFinal: false)
        #expect(controller.state == .idle)
        #expect(states.contains(.dictating(text: "你")))
        #expect(states.contains(.dictating(text: "你好")))
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func dictationFinalResultStopsWithoutSending() async {
        guard #available(iOS 26.0, *) else { return }
        let transcriber = ControlledSpeechTranscriber()
        let controller = AudioController(
            audioSession: RecordingAudioSession(),
            fileManager: .default,
            speechTranscriber: transcriber,
            permissionProvider: ControlledMediaPermissions(
                microphoneGranted: true,
                speechGranted: true
            )
        )
        var latestDraft = ""
        controller.stateDidChange = { state in
            if case .dictating(let text) = state {
                latestDraft = text
            }
        }

        controller.startDictation(locale: Locale(identifier: "ar"))
        #expect(await waitForCondition { transcriber.startCount == 1 })
        #expect(transcriber.locale?.identifier == "ar-SA")
        transcriber.emit(text: "مرحبا", isFinal: true)

        #expect(latestDraft == "مرحبا")
        #expect(controller.state == .idle)
        #expect(transcriber.stopCount == 1)
    }

    /// 无效输入格式通过启动错误返回后，应恢复编辑状态、释放会话并允许重试。
    @Test(.enabled(if: ChatTestAvailability.isSupported)) func dictationInvalidInputReleasesSessionAndAllowsRetry() async {
        guard #available(iOS 26.0, *) else { return }
        let transcriber = ControlledSpeechTranscriber()
        transcriber.startError = SpeechInputFormat.ValidationError.unavailable
        let audioSession = RecordingAudioSession()
        let controller = AudioController(
            audioSession: audioSession,
            fileManager: .default,
            speechTranscriber: transcriber,
            permissionProvider: ControlledMediaPermissions(microphoneGranted: true, speechGranted: true)
        )
        defer { controller.stopAll() }
        var failure: MediaFailure?
        controller.failureDidOccur = { failure = $0 }
        controller.startDictation(locale: Locale(identifier: "zh-CN"))
        #expect(await waitForCondition { failure == .speechUnavailable })
        #expect(controller.state == .idle)
        #expect(audioSession.deactivationCount == 1)
        #expect(transcriber.stopCount == 1)

        transcriber.startError = nil
        controller.startDictation(locale: Locale(identifier: "zh-CN"))
        #expect(await waitForCondition { controller.state == .dictating(text: "") })
        #expect(transcriber.startCount == 2)
        #expect(audioSession.captureActivationCount == 2)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func dictationPermissionFailureDoesNotStartCapture() async {
        guard #available(iOS 26.0, *) else { return }
        let transcriber = ControlledSpeechTranscriber()
        let audioSession = RecordingAudioSession()
        let controller = AudioController(
            audioSession: audioSession,
            fileManager: .default,
            speechTranscriber: transcriber,
            permissionProvider: ControlledMediaPermissions(
                microphoneGranted: false,
                speechGranted: true
            )
        )
        var failure: MediaFailure?
        controller.failureDidOccur = { failure = $0 }

        controller.startDictation(locale: Locale(identifier: "en-US"))
        #expect(
            await waitForCondition {
                failure == .microphonePermissionDenied
            }
        )
        #expect(controller.state == .idle)
        #expect(transcriber.startCount == 0)
        #expect(audioSession.captureActivationCount == 0)
    }
}

/// iMessage 媒体测试使用的确定性语音转写器。
@available(iOS 26.0, *)
@MainActor
private final class ControlledSpeechTranscriber:
    SpeechTranscribing {

    private var result: (@MainActor (String, Bool) -> Void)?
    private var failure: (@MainActor () -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var locale: Locale?
    /// 本次启动需要模拟的错误；清空后可用于验证重试。
    var startError: (any Error)?

    func start(
        locale: Locale,
        result: @escaping @MainActor (String, Bool) -> Void,
        failure: @escaping @MainActor () -> Void
    ) async throws {
        startCount += 1
        if let startError { throw startError }
        self.locale = locale
        self.result = result
        self.failure = failure
    }

    func stop() {
        stopCount += 1
    }

    func emit(text: String, isFinal: Bool) {
        result?(text, isFinal)
    }

    func fail() {
        failure?()
    }
}

/// iMessage 媒体测试使用的确定性权限提供者。
@available(iOS 26.0, *)
@MainActor
private final class ControlledMediaPermissions:
    MediaPermissionProviding {

    let microphoneGranted: Bool
    let speechGranted: Bool

    init(microphoneGranted: Bool, speechGranted: Bool) {
        self.microphoneGranted = microphoneGranted
        self.speechGranted = speechGranted
    }

    func requestMicrophonePermission() async -> Bool {
        microphoneGranted
    }

    func requestSpeechPermission() async -> Bool {
        speechGranted
    }
}

/// 不执行真实操作，仅为测试记录激活请求的音频会话。
@available(iOS 26.0, *)
@MainActor
private final class RecordingAudioSession:
    NSObject,
    AudioSessionControlling {

    var notificationObject: AnyObject { self }

    private(set) var captureActivationCount = 0
    private(set) var playbackActivationCount = 0
    private(set) var deactivationCount = 0

    func activateCapture() async throws {
        captureActivationCount += 1
    }

    func activatePlayback() async throws {
        playbackActivationCount += 1
    }

    func activatePreviewPlayback() async throws { try await activatePlayback() }

    func deactivate() {
        deactivationCount += 1
    }
}
