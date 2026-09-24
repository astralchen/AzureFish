import AVFAudio
import Foundation
import Speech
import Testing
import XCTest
@testable import AzureFish

/// 验证无效麦克风格式在安装 tap 前可被拒绝，以及取消不会启动系统识别。
@MainActor
struct ChatSpeechInputFormatTests {
    /// 从 MainActor 创建生产 tap 后，模拟 AVFAudio 在后台队列同步调用。
    @Test func legacyAudioTapRunsOnAudioQueue() async throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let tap = AudioTapTransfer(SpeechRecognitionCallbacks.legacyAudioTap(request: request))
        await invokeOnAudioQueue(tap)
        request.endAudio()
    }

    /// 现代后端也必须跨过相同隔离边界，并将真实缓冲区送入分析流。
    @Test func modernAudioTapForwardsBufferOnAudioQueue() async throws {
        guard #available(iOS 26.0, *) else { return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let tap = AudioTapTransfer(SpeechRecognitionCallbacks.modernAudioTap(continuation: continuation))
        await invokeOnAudioQueue(tap)
        continuation.finish()
        var count = 0
        for await input in stream {
            #expect(input.buffer.frameLength == 128)
            #expect(input.buffer.format.sampleRate == 16_000)
            count += 1
        }
        #expect(count == 1)
    }

    /// 系统后台错误回调必须先进入主 Actor，才能读取 operation 和通知 UI。
    @Test func legacyFailureReturnsToMainActor() async {
        let scope = OperationScope()
        let received = XCTestExpectation(description: "主 Actor 收到识别错误")
        let callback = SpeechRecognitionCallbacks.legacyResultHandler(
            operation: scope.begin(),
            result: { _, _ in Issue.record("错误回调不应生成文本") },
            failure: {
                MainActor.assertIsolated()
                received.fulfill()
            }
        )
        await Task.detached { callback(nil, CocoaError(.featureUnsupported)) }.value
        let outcome = await XCTWaiter.fulfillment(of: [received], timeout: 2)
        #expect(outcome == .completed)
    }

    /// 已停止或被替换会话的后台回调不得污染新一轮输入。
    @Test(arguments: [false, true])
    func legacyFailureIgnoresStaleOperation(replace: Bool) async {
        let scope = OperationScope()
        let received = XCTestExpectation(description: "过期回调应被忽略")
        received.isInverted = true
        let callback = SpeechRecognitionCallbacks.legacyResultHandler(
            operation: scope.begin(),
            result: { _, _ in received.fulfill() },
            failure: { received.fulfill() }
        )
        if replace { _ = scope.begin() } else { scope.invalidate() }
        await Task.detached { callback(nil, CocoaError(.featureUnsupported)) }.value
        let outcome = await XCTWaiter.fulfillment(of: [received], timeout: 0.1)
        #expect(outcome == .completed)
    }

    /// 重现日志中的双声道、零采样率格式，错误应通过 Swift 返回。
    @Test func rejectsZeroSampleRateWithTwoChannels() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 0, channels: 2))
        #expect(throws: SpeechInputFormat.ValidationError.self) {
            try SpeechInputFormat.validate(format)
        }
    }

    /// 没有声道的输入不能被当成可录音设备。
    @Test func rejectsZeroChannels() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 0))
        #expect(throws: SpeechInputFormat.ValidationError.self) {
            try SpeechInputFormat.validate(format)
        }
    }

    /// 保留真实设备常见的采样率和声道配置。
    @Test(arguments: [16_000.0, 44_100.0, 48_000.0], [AVAudioChannelCount(1), 2])
    func acceptsValidCaptureFormat(sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        try SpeechInputFormat.validate(format)
    }

    /// 已取消的请求在访问麦克风或语言模型前结束，两个后端均不发布回调。
    @Test(arguments: [SpeechBackend.speechAnalyzer, .speechRecognizer])
    func cancelledStartDoesNotActivateBackend(backend: SpeechBackend) async throws {
        guard #available(iOS 26.0, *) else { return }
        let service = SpeechRecognitionService(backend: backend)
        var callbackCount = 0
        let task = Task { @MainActor in
            try await service.start(locale: Locale(identifier: "zh-CN")) { _, _ in
                callbackCount += 1
            } failure: {
                callbackCount += 1
            }
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("已取消的识别请求不应启动成功")
        } catch is CancellationError {
            #expect(callbackCount == 0)
        }
        service.stop()
    }
}

/// 仅在测试中模拟 Objective-C 音频 API 保存并跨队列调用非 Sendable block。
/// tap 只调用一次；PCM 缓冲区也只在音频队列创建和提交。
private struct AudioTapTransfer: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock

    init(_ callback: @escaping AVAudioNodeTapBlock) {
        self.callback = callback
    }
}

private func invokeOnAudioQueue(_ tap: AudioTapTransfer) async {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "SpeechRecognitionTests.audioQueue").async {
            #expect(!Thread.isMainThread)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128
            buffer.int16ChannelData![0].initialize(repeating: 0, count: 128)
            tap.callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            continuation.resume()
        }
    }
}
