import AVFAudio
import CoreGraphics
import Testing
import UIKit
import AppLocalization
import QuickLayoutKit
@_spi(Testing) import QuickLayoutKitUIKit
@testable import AzureFish

extension DemoTests {

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatSendReplyAndReadFlowIsDeterministic() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let localizer = Localizer { key, _ in "localized.\(key)" }
        let viewModel = ChatViewModel(
            localizer: localizer,
            clock: { fixedDate },
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )
        var updateReasons: [ChatViewModel.UpdateReason] = []
        viewModel.bind { _, reason in
            updateReasons.append(reason)
        }

        let initialIDs = viewModel.state.timeline.map(\.id)
        #expect(!viewModel.send("  \n  "))
        #expect(viewModel.state.timeline.map(\.id) == initialIDs)

        #expect(viewModel.send("  hello\nworld  "))
        #expect(
            await waitForCondition {
                sleeper.requestedDurations == [.milliseconds(900)]
            }
        )
        #expect(viewModel.state.isTyping)
        #expect(viewModel.state.timeline.last?.id == .typing)

        let sendingMessages = viewModel.state.timeline.compactMap {
            item -> MessagePresentation? in
            guard case .message(let message) = item.content else {
                return nil
            }
            return message
        }
        let sendingMessage = try #require(sendingMessages.last)
        #expect(sendingMessage.id == 0)
        #expect(sendingMessage.text == "hello\nworld")
        #expect(
            sendingMessage.deliveryText
                == "localized.imessage.status.read"
        )
        #expect(
            sendingMessages
                .filter { $0.direction == .outgoing }
                .compactMap(\.deliveryText)
                == ["localized.imessage.status.read"]
        )

        sleeper.succeed()
        #expect(await waitForCondition { !viewModel.state.isTyping })

        let repliedMessages = viewModel.state.timeline.compactMap {
            item -> MessagePresentation? in
            guard case .message(let message) = item.content else {
                return nil
            }
            return message
        }
        let readMessage = try #require(
            repliedMessages.first(where: { $0.id == 0 })
        )
        let reply = try #require(repliedMessages.last)
        #expect(readMessage.deliveryText == "localized.imessage.status.read")
        #expect(reply.id == 1)
        #expect(reply.direction == .incoming)
        #expect(reply.text == "localized.imessage.reply.1")
        #expect(
            updateReasons.first == .initial && updateReasons.contains(.sentMessage) && updateReasons.contains(.receivedMessage)
        )
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatRelocalizesFixturesWithoutRewritingUserText() throws {
        guard #available(iOS 26.0, *) else { return }
        let localization = MutableLocalization(prefix: "first")
        let sleeper = ControlledSleeper()
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in
                localization.text(for: key)
            },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        viewModel.insertInitialHistory([.init(direction: .incoming,
            content: .localized(key: "imessage.seed.incoming.1"))])
        #expect(viewModel.send("用户原始文本\nsecond line"))
        viewModel.cancelPendingReply()
        localization.prefix = "second"
        viewModel.refreshLocalizedContent()

        let messages = viewModel.state.timeline.compactMap {
            item -> MessagePresentation? in
            guard case .message(let message) = item.content else {
                return nil
            }
            return message
        }
        let localizedSeed = try #require(
            messages.first(where: { $0.id == 0 })
        )
        let userMessage = try #require(
            messages.first(where: { $0.id == 1 })
        )
        #expect(
            localizedSeed.text == "second.imessage.seed.incoming.1"
        )
        #expect(userMessage.text == "用户原始文本\nsecond line")
        #expect(!viewModel.state.isTyping)
        #expect(viewModel.state.timeline.last?.id == .message(1))
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatAudioUsesOutgoingReplyAndReadLifecycle() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data([0]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let attachment = AudioAttachment(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            fileURL: fileURL,
            duration: 3.25,
            waveform: [0, 0.4, 2]
        )
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        #expect(viewModel.sendAttachment(.audio(attachment)))
        #expect(
            await waitForCondition {
                sleeper.requestedDurations == [.milliseconds(900)]
            }
        )

        let sendingMessage = try #require(
            viewModel.state.timeline.compactMap {
                item -> MessagePresentation? in
                guard case .message(let message) = item.content,
                      message.id == 0 else { return nil }
                return message
            }.first
        )
        let sentAttachment = try #require(sendingMessage.audio)
        #expect(sentAttachment == attachment)
        #expect(sentAttachment.waveform == [0.08, 0.4, 1])
        #expect(
            sendingMessage.deliveryText
                == "localized.imessage.status.read"
        )
        #expect(!viewModel.state.isTyping)

        sleeper.succeed()
        #expect(await waitForCondition { !viewModel.state.isProcessingMessages })
        let readMessage = try #require(
            viewModel.state.timeline.compactMap {
                item -> MessagePresentation? in
                guard case .message(let message) = item.content,
                      message.id == 0 else { return nil }
                return message
            }.first
        )
        #expect(readMessage.audio == attachment)
        #expect(readMessage.deliveryText == "localized.imessage.status.read")
        #expect(viewModel.state.timeline.last?.id == .message(1))
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatTextReplyDoesNotStartAudioSynthesis() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let synthesizer = ControlledReplyAudioSynthesizer()
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            localeProvider: { Locale(identifier: "zh-Hans") },
            replyAudioSynthesizer: synthesizer,
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        #expect(viewModel.send("hello"))
        #expect(
            await waitForCondition {
                sleeper.requestedDurations == [.milliseconds(900)]
            }
        )
        #expect(synthesizer.requests.isEmpty)
        sleeper.succeed()
        #expect(await waitForCondition { !viewModel.state.isProcessingMessages })

        let reply = try #require(
            viewModel.state.timeline.compactMap {
                item -> MessagePresentation? in
                guard case .message(let message) = item.content,
                      message.direction == .incoming else { return nil }
                return message
            }.last
        )
        #expect(reply.text == "localized.imessage.reply.1")
        #expect(reply.audio == nil)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatAudioReplyWaitsForDelayAndSynthesis() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let synthesizer = ControlledReplyAudioSynthesizer()
        let outgoingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let replyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        try Data([0]).write(to: outgoingURL)
        try Data([1]).write(to: replyURL)
        defer {
            try? FileManager.default.removeItem(at: outgoingURL)
            try? FileManager.default.removeItem(at: replyURL)
        }
        let outgoingAttachment = AudioAttachment(
            fileURL: outgoingURL,
            duration: 2,
            waveform: [0.3, 0.6]
        )
        let replyAttachment = AudioAttachment(
            id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
            fileURL: replyURL,
            duration: 1.75,
            waveform: [0.2, 0.8]
        )
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            localeProvider: { Locale(identifier: "zh-Hans") },
            replyAudioSynthesizer: synthesizer,
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        #expect(viewModel.sendAttachment(.audio(outgoingAttachment)))
        #expect(
            await waitForCondition {
                sleeper.requestedDurations == [.milliseconds(900)]
                    && synthesizer.requests.count == 1
            }
        )
        #expect(
            synthesizer.requests.first?.text
                == "localized.imessage.reply.1"
        )
        #expect(synthesizer.requests.first?.locale.identifier == "zh-CN")

        sleeper.succeed()
        await Task.yield()
        #expect(viewModel.state.isProcessingMessages)
        #expect(!viewModel.state.isTyping)

        synthesizer.succeed(with: replyAttachment)
        #expect(await waitForCondition { !viewModel.state.isProcessingMessages })
        let messages = viewModel.state.timeline.compactMap {
            item -> MessagePresentation? in
            guard case .message(let message) = item.content else { return nil }
            return message
        }
        let sentMessage = try #require(messages.first(where: { $0.id == 0 }))
        let reply = try #require(messages.first(where: { $0.id == 1 }))
        #expect(sentMessage.deliveryText == "localized.imessage.status.read")
        #expect(reply.direction == .incoming)
        #expect(reply.audio == replyAttachment)
        #expect(reply.text.isEmpty)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatAudioReplyFallsBackToSameAudioType() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let synthesizer = ControlledReplyAudioSynthesizer()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data([0]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            localeProvider: { Locale(identifier: "ar") },
            replyAudioSynthesizer: synthesizer,
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        #expect(
            viewModel.sendAttachment(
                .audio(AudioAttachment(
                    fileURL: fileURL,
                    duration: 1,
                    waveform: [0.5]
                ))
            )
        )
        #expect(
            await waitForCondition {
                sleeper.requestedDurations == [.milliseconds(900)]
                    && synthesizer.requests.count == 1
            }
        )
        synthesizer.fail()
        #expect(viewModel.state.isProcessingMessages)
        sleeper.succeed()
        #expect(await waitForCondition { !viewModel.state.isProcessingMessages })

        let reply = try #require(
            viewModel.state.timeline.compactMap {
                item -> MessagePresentation? in
                guard case .message(let message) = item.content,
                      message.id == 1 else { return nil }
                return message
            }.first
        )
        #expect(synthesizer.requests.first?.locale.identifier == "ar-SA")
        #expect(reply.text.isEmpty)
        #expect(reply.audio?.fileURL == fileURL)
        #expect(reply.audio?.duration == 1)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatCancelsPendingAudioReplyWithoutAppendingIt()
        async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let synthesizer = ControlledReplyAudioSynthesizer()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data([0]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            localeProvider: { Locale(identifier: "en") },
            replyAudioSynthesizer: synthesizer,
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        #expect(
            viewModel.sendAttachment(
                .audio(AudioAttachment(
                    fileURL: fileURL,
                    duration: 1,
                    waveform: [0.5]
                ))
            )
        )
        #expect(
            await waitForCondition {
                sleeper.requestedDurations == [.milliseconds(900)]
                    && synthesizer.requests.count == 1
            }
        )

        viewModel.cancelPendingReply()
        sleeper.succeed()
        #expect(
            await waitForCondition {
                synthesizer.cancellationCount == 1
            }
        )
        #expect(!viewModel.state.isProcessingMessages)
        #expect(
            !viewModel.state.timeline.contains(where: {
                $0.id == .message(1)
            })
        )
        let sentMessage = try #require(
            viewModel.state.timeline.compactMap {
                item -> MessagePresentation? in
                guard case .message(let message) = item.content,
                      message.id == 0 else { return nil }
                return message
            }.first
        )
        #expect(
            sentMessage.deliveryText
                == "localized.imessage.status.read"
        )
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatNewAudioMessageQueuesBehindOlderSynthesis()
        async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        let synthesizer = ControlledReplyAudioSynthesizer()
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let replyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        for url in [firstURL, secondURL, replyURL] {
            try Data([0]).write(to: url)
        }
        defer {
            for url in [firstURL, secondURL, replyURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            localeProvider: { Locale(identifier: "en") },
            replyAudioSynthesizer: synthesizer,
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )

        #expect(
            viewModel.sendAttachment(
                .audio(AudioAttachment(
                    fileURL: firstURL,
                    duration: 1,
                    waveform: [0.3]
                ))
            )
        )
        #expect(
            await waitForCondition {
                synthesizer.requests.count == 1
            }
        )
        #expect(
            viewModel.sendAttachment(
                .audio(AudioAttachment(
                    fileURL: secondURL,
                    duration: 1,
                    waveform: [0.6]
                ))
            )
        )
        #expect(synthesizer.requests.count == 1)
        sleeper.succeed()
        synthesizer.succeed(with: AudioAttachment(
            fileURL: firstURL, duration: 1, waveform: [0.3]
        ))
        #expect(await waitForCondition {
            synthesizer.requests.count == 2 && sleeper.requestedDurations.count == 2
        })
        #expect(synthesizer.cancellationCount == 0)
        sleeper.succeed()
        synthesizer.succeedLatest(
            with: AudioAttachment(
                fileURL: replyURL,
                duration: 1.25,
                waveform: [0.2, 0.9]
            )
        )
        #expect(await waitForCondition { !viewModel.state.isProcessingMessages })

        let messages = viewModel.state.timeline.compactMap {
            item -> MessagePresentation? in
            guard case .message(let message) = item.content else {
                return nil
            }
            return message
        }
        #expect(messages.count == 4)
        #expect(messages.filter { $0.direction == .incoming }
            .map(\.id) == [2, 3])
        #expect(messages.first(where: { $0.id == 2 })?.audio?.fileURL == firstURL)
        #expect(messages.first(where: { $0.id == 3 })?.audio?.fileURL == replyURL)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatRejectsInvalidAudioAndPreservesAudioOnLocalization()
        throws {
        guard #available(iOS 26.0, *) else { return }
        let localization = MutableLocalization(prefix: "first")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data([0]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let sleeper = ControlledSleeper()
        let viewModel = ChatViewModel(
            localizer: Localizer { key, _ in
                localization.text(for: key)
            },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            sleeper: { duration in
                try await sleeper.sleep(duration)
            }
        )
        let tooShort = AudioAttachment(
            fileURL: fileURL,
            duration: 0.99,
            waveform: [0.5]
        )
        #expect(!viewModel.sendAttachment(.audio(tooShort)))

        let attachment = AudioAttachment(
            fileURL: fileURL,
            duration: 1,
            waveform: [0.25, 0.75]
        )
        #expect(viewModel.sendAttachment(.audio(attachment)))
        viewModel.cancelPendingReply()
        localization.prefix = "second"
        viewModel.refreshLocalizedContent()

        let audio = try #require(
            viewModel.state.timeline.compactMap {
                item -> AudioAttachment? in
                guard case .message(let message) = item.content,
                      message.id == 0 else { return nil }
                return message.audio
            }.first
        )
        #expect(audio == attachment)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func speechConfigurationMapsBackendsAndLocales() {
        guard #available(iOS 26.0, *) else { return }
        #expect(
            SpeechConfiguration.preferredBackend(
                supportsSpeechAnalyzer: true
            ) == .speechAnalyzer
        )
        #expect(
            SpeechConfiguration.preferredBackend(
                supportsSpeechAnalyzer: false
            ) == .speechRecognizer
        )
        #expect(
            SpeechConfiguration.fallbackBackend(
                afterFailureOf: .speechAnalyzer,
                wasExplicitlyRequested: false
            ) == .speechRecognizer
        )
        #expect(
            SpeechConfiguration.fallbackBackend(
                afterFailureOf: .speechAnalyzer,
                wasExplicitlyRequested: true
            ) == nil
        )
        #expect(
            SpeechConfiguration.fallbackBackend(
                afterFailureOf: .speechRecognizer,
                wasExplicitlyRequested: false
            ) == nil
        )
        #expect(
            SpeechConfiguration.recognitionLocale(
                for: Locale(identifier: "zh-Hans")
            ).identifier == "zh-CN"
        )
        #expect(
            SpeechConfiguration.recognitionLocale(
                for: Locale(identifier: "ar")
            ).identifier == "ar-SA"
        )
        #expect(
            SpeechConfiguration.recognitionLocale(
                for: Locale(identifier: "en-GB")
            ).identifier == "en-US"
        )
        #expect(
            SpeechConfiguration.speechLocale(
                for: Locale(identifier: "zh-Hans")
            ).identifier == "zh-CN"
        )
        #expect(
            SpeechConfiguration.speechLocale(
                for: Locale(identifier: "ar")
            ).identifier == "ar-SA"
        )
        #expect(
            SpeechConfiguration.speechLocale(
                for: Locale(identifier: "en-GB")
            ).identifier == "en-US"
        )
        #expect(
            SpeechConfiguration.speechVoiceLanguage(
                for: Locale(identifier: "zh-CN")
            ) == "zh-CN"
        )
        #expect(
            SpeechConfiguration.speechVoiceLanguage(
                for: Locale(identifier: "en-US")
            ) == "en-US"
        )
        #expect(
            SpeechConfiguration.speechVoiceLanguage(
                for: Locale(identifier: "ar-SA")
            ) == "ar-SA"
        )
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func chatViewModelCancelsReplyWhenReleased() async {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = ControlledSleeper()
        weak var releasedViewModel: ChatViewModel?

        do {
            let viewModel = ChatViewModel(
                localizer: Localizer { key, _ in key },
                clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                sleeper: { duration in
                    try await sleeper.sleep(duration)
                }
            )
            releasedViewModel = viewModel
            #expect(viewModel.send("temporary"))
            #expect(
                await waitForCondition {
                    sleeper.requestedDurations == [.milliseconds(900)]
                }
            )
        }

        #expect(releasedViewModel == nil)
        sleeper.succeed()
    }
}

@available(iOS 26.0, *)
@MainActor
private final class ControlledSleeper {

    private(set) var requestedDurations: [Duration] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func sleep(_ duration: Duration) async throws {
        // 状态分阶段用例在 ChatMessageStatusTests 中逐步控制阅读等待。
        if duration == .milliseconds(300) { return }
        requestedDurations.append(duration)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeed() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: ())
    }
}

/// iMessage 模拟回复测试使用的确定性音频合成器。
@available(iOS 26.0, *)
@MainActor
private final class ControlledReplyAudioSynthesizer:
    ReplyAudioSynthesizing {

    struct Request {
        let text: String
        let locale: Locale
    }

    private(set) var requests: [Request] = []
    private(set) var cancellationCount = 0
    private var continuations: [Int: CheckedContinuation<
        AudioAttachment,
        any Error
    >] = [:]

    func synthesizeReplyAudio(
        text: String,
        locale: Locale
    ) async throws -> AudioAttachment {
        let requestID = requests.count
        requests.append(Request(text: text, locale: locale))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                cancellationCount += 1
                continuations.removeValue(forKey: requestID)?
                    .resume(throwing: CancellationError())
            }
        }
    }

    func succeed(with attachment: AudioAttachment) {
        guard let requestID = continuations.keys.min() else { return }
        continuations.removeValue(forKey: requestID)?
            .resume(returning: attachment)
    }

    func succeedLatest(with attachment: AudioAttachment) {
        guard let requestID = continuations.keys.max() else { return }
        continuations.removeValue(forKey: requestID)?
            .resume(returning: attachment)
    }

    func fail() {
        guard let requestID = continuations.keys.min() else { return }
        continuations.removeValue(forKey: requestID)?.resume(
            throwing: ReplyAudioSynthesisError.fileWriteFailed
        )
    }
}

@available(iOS 26.0, *)
@MainActor
private final class MutableLocalization {

    var prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    func text(for key: String) -> String {
        "\(prefix).\(key)"
    }
}
