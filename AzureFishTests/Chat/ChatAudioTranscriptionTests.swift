import OSLog
import Foundation
import AVFAudio
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

private let logger = Logger(subsystem: "AzureFish.Tests", category: "ChatAudioTranscriptionTests")

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatAudioTranscriptionTests {
    @Test func sendsFirstThenUpdatesSameMessageAndPreservesDeliveryAndMetadata() async throws {
        guard #available(iOS 26.0, *) else { return }
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio.fileURL) }
        let model = makeModel()
        defer { model.cancelPendingReply() }
        let transcriber = ControlledFileTranscriber()
        let coordinator = makeCoordinator(model, transcriber)
        defer { coordinator.cancelAll() }
        var reasons: [ChatViewModel.UpdateReason] = []
        model.bind { state, reason in
            reasons.append(reason)
            coordinator.enqueue(state, locale: Locale(identifier: "zh-CN"))
        }
        #expect(model.sendAttachment(.audio(audio)))
        let initial = try #require(audioMessages(model.state).first)
        let ids = model.state.timeline.map(\.id)
        #expect(initial.audio?.transcript == nil)
        #expect(transcriber.calls.isEmpty) // 同步发送和提交有机会先完成。
        #expect(await eventually { transcriber.calls.count == 1 })
        transcriber.resolve(.success("  你好，你吃饭了吗？\n"))
        #expect(await eventually { audioMessages(model.state).first?.audio?.transcript != nil })
        let updated = try #require(audioMessages(model.state).first)
        #expect(updated.id == initial.id)
        #expect(updated.audio?.id == audio.id)
        #expect(updated.audio?.fileURL == audio.fileURL)
        #expect(updated.audio?.duration == audio.duration)
        #expect(updated.audio?.waveform == audio.waveform)
        #expect(updated.audio?.transcript == "你好，你吃饭了吗？")
        #expect(updated.deliveryText == initial.deliveryText)
        #expect(updated.refreshIdentity != initial.refreshIdentity)
        #expect(model.state.timeline.map(\.id) == ids)
        #expect(reasons == [.initial, .sentMessage, .audioTranscript])
        #expect(FileManager.default.fileExists(atPath: audio.fileURL.path))
        #expect(!model.updateAudioTranscript("wrong", messageID: initial.id, attachmentID: UUID()))
        #expect(!model.updateAudioTranscript("repeat", messageID: initial.id, attachmentID: audio.id))
    }

    @Test func batchAndNewMessagesQueueOnceAndFreezeTheirLanguage() async throws {
        guard #available(iOS 26.0, *) else { return }
        let first = try makeAudio(), second = try makeAudio(), third = try makeAudio()
        defer { for audio in [first, second, third] { try? FileManager.default.removeItem(at: audio.fileURL) } }
        let model = makeModel()
        defer { model.cancelPendingReply() }
        let transcriber = ControlledFileTranscriber()
        let coordinator = makeCoordinator(model, transcriber)
        defer { coordinator.cancelAll() }
        var locale = Locale(identifier: "zh-CN")
        model.bind { state, _ in coordinator.enqueue(state, locale: locale) }
        #expect(model.sendContents([.attachment(.audio(first)), .attachment(.audio(second))]))
        #expect(await eventually { transcriber.calls.count == 1 })
        locale = Locale(identifier: "en-US")
        model.refreshLocalizedContent()
        #expect(model.sendAttachment(.audio(third)))
        #expect(transcriber.calls.count == 1)
        transcriber.resolve(.success("一"))
        #expect(await eventually { transcriber.calls.count == 2 })
        #expect(transcriber.calls[1].locale.identifier == "zh-CN")
        transcriber.resolve(.success("二"))
        #expect(await eventually { transcriber.calls.count == 3 })
        #expect(transcriber.calls[2].locale.identifier == "en-US")
        transcriber.resolve(.success("three"))
        #expect(await eventually { audioMessages(model.state).allSatisfy { $0.audio?.transcript != nil } })
        model.refreshLocalizedContent()
        #expect(transcriber.calls.map(\.url) == [first.fileURL, second.fileURL, third.fileURL])
    }

    @Test func failuresAndBlankResultsStayAudioOnlyAndDoNotRetry() async throws {
        guard #available(iOS 26.0, *) else { return }
        let first = try makeAudio(), second = try makeAudio()
        defer { for audio in [first, second] { try? FileManager.default.removeItem(at: audio.fileURL) } }
        let model = makeModel()
        defer { model.cancelPendingReply() }
        let transcriber = ControlledFileTranscriber()
        let coordinator = makeCoordinator(model, transcriber)
        defer { coordinator.cancelAll() }
        model.bind { state, _ in coordinator.enqueue(state, locale: Locale(identifier: "zh-CN")) }
        #expect(model.sendContents([.attachment(.audio(first)), .attachment(.audio(second))]))
        #expect(await eventually { transcriber.calls.count == 1 })
        transcriber.resolve(.failure(CocoaError(.featureUnsupported)))
        #expect(await eventually { transcriber.calls.count == 2 })
        transcriber.resolve(.success(" \n "))
        await Task.yield()
        model.refreshLocalizedContent()
        #expect(audioMessages(model.state).allSatisfy { $0.audio?.transcript == nil })
        #expect(transcriber.calls.count == 2)
    }

    @Test func deniedSpeechPermissionDoesNotRequestMicrophoneOrProduceText() async throws {
        guard #available(iOS 26.0, *) else { return }
        let permissions = DeniedFilePermissions()
        let service = AudioFileTranscriber(backend: .speechRecognizer, permissionProvider: permissions)
        let text = try await service.transcribe(fileURL: fixtureAudio().fileURL, locale: Locale(identifier: "zh-CN"))
        #expect(text == nil)
        #expect(permissions.speechRequests == 1)
        #expect(permissions.microphoneRequests == 0)
    }

    @Test func cancellationIgnoresLateResultAndDropsQueuedFiles() async throws {
        guard #available(iOS 26.0, *) else { return }
        let first = try makeAudio(), second = try makeAudio()
        defer { for audio in [first, second] { try? FileManager.default.removeItem(at: audio.fileURL) } }
        let model = makeModel()
        defer { model.cancelPendingReply() }
        let transcriber = ControlledFileTranscriber()
        let coordinator = makeCoordinator(model, transcriber)
        model.bind { state, _ in coordinator.enqueue(state, locale: Locale(identifier: "zh-CN")) }
        #expect(model.sendContents([.attachment(.audio(first)), .attachment(.audio(second))]))
        #expect(await eventually { transcriber.calls.count == 1 })
        coordinator.cancelAll()
        transcriber.resolve(.success("迟到结果"))
        for _ in 0..<5 { await Task.yield() }
        model.refreshLocalizedContent()
        #expect(audioMessages(model.state).allSatisfy { $0.audio?.transcript == nil })
        #expect(transcriber.calls.count == 1)
    }

    @Test func receivedAudioIsInsertedBeforeItsFileIsTranscribed() async throws {
        guard #available(iOS 26.0, *) else { return }
        let outgoing = try makeAudio(), incoming = try makeAudio()
        defer { for audio in [outgoing, incoming] { try? FileManager.default.removeItem(at: audio.fileURL) } }
        let model = ChatViewModel(
            localizer: Localizer { key, _ in key }, clock: Date.init,
            replyAudioSynthesizer: ReplySynthesizer(audio: incoming),
            sleeper: { _ in try await Task.sleep(nanoseconds: 10_000_000) }
        )
        defer { model.cancelPendingReply() }
        let transcriber = ControlledFileTranscriber()
        let coordinator = makeCoordinator(model, transcriber)
        defer { coordinator.cancelAll() }
        var receivedWithoutTranscript = false
        model.bind { state, reason in
            if reason == .receivedMessage {
                receivedWithoutTranscript = audioMessages(state).last?.audio?.transcript == nil
            }
            coordinator.enqueue(state, locale: Locale(identifier: "zh-CN"))
        }
        #expect(model.sendAttachment(.audio(outgoing)))
        #expect(await eventually { audioMessages(model.state).count == 2 && transcriber.calls.count == 1 })
        #expect(receivedWithoutTranscript)
        transcriber.resolve(.success(nil))
        #expect(await eventually { transcriber.calls.count == 2 })
        #expect(transcriber.calls[1].url == incoming.fileURL)
        let delivery = audioMessages(model.state).first?.deliveryText
        transcriber.resolve(.success("收到音频的识别结果"))
        #expect(await eventually { audioMessages(model.state).last?.audio?.transcript != nil })
        #expect(audioMessages(model.state).last?.direction == .incoming)
        #expect(audioMessages(model.state).first?.deliveryText == delivery)
    }

    @Test func audioBodyMeasuresBeforeLayoutAcrossWidthsAndDirections() {
        guard #available(iOS 26.0, *) else { return }
        for direction in [MessageDirection.incoming, .outgoing] {
            for rtl in [false, true] {
                let cell = AudioBubbleCell(frame: .zero)
                cell.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                var audio = fixtureAudio()
                audio.transcript = String(repeating: "这段转写需要随可用宽度换行。", count: 8)
                configure(cell, audio: audio, direction: direction)
                for width: CGFloat in [402, 200, 320, 1024] {
                    let measured = cell.sizeThatFits(CGSize(width: width, height: 52))
                    layout(cell, width: width)
                    #expect(abs(cell.bounds.height - measured.height) < 1)
                    let bubble = cell.bubbleView.convert(cell.bubbleView.bounds, to: cell)
                    #expect(abs(bubble.width - min(width - 24, min(420, max(230, width * 0.70)))) < 1)
                    #expect(bubble.minX >= 11 && bubble.maxX <= width - 11)
                    #expect(bubble.maxY <= cell.bounds.height - 1)
                    let transcript = cell.bubbleView.transcriptLabel
                    let textHeight = transcript.sizeThatFits(CGSize(width: transcript.bounds.width, height: .infinity)).height
                    #expect(transcript.bounds.height >= textHeight - 1)
                }
            }
        }
    }

    @Test func transcriptResizesBubbleAndSurvivesPlaybackWhileReuseClearsIt() {
        guard #available(iOS 26.0, *) else { return }
        for direction in [MessageDirection.incoming, .outgoing] {
            for rtl in [false, true] {
                let cell = AudioBubbleCell(frame: .zero)
                cell.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                var audio = fixtureAudio()
                configure(cell, audio: audio, direction: direction)
                layout(cell, width: 402)
                let plainHeight = cell.bounds.height
                #expect(cell.bubbleView.transcriptLabel.superview == nil)
                audio.transcript = String(repeating: "你好，你吃饭了吗？", count: 12)
                configure(cell, audio: audio, direction: direction)
                layout(cell, width: 402)
                #expect(cell.bubbleView.transcriptLabel.isDescendant(of: cell.bubbleView))
                #expect(!cell.bubbleView.transcriptLabel.isHidden)
                #expect(cell.bounds.height > plainHeight + 40)
                #expect(cell.bubbleView.transcriptLabel.bounds.height > 30)
                #expect(cell.bubbleView.playButton.bounds.width >= 44)
                #expect(cell.bubbleView.playButton.bounds.height >= 44)
                #expect(cell.bubbleView.waveformView.bounds.width > 50)
                let bubble = cell.bubbleView.convert(cell.bubbleView.bounds, to: cell)
                let trailing = direction == .outgoing ? !rtl : rtl
                #expect(abs((trailing ? 390 - bubble.maxX : bubble.minX - 12)) < 1)
                cell.updatePlayback(.init(messageID: 7, attachmentID: audio.id, isPlaying: true, progress: 0.5), playAccessibilityLabel: "播放", pauseAccessibilityLabel: "暂停")
                #expect(cell.bubbleView.transcriptLabel.text == audio.transcript)
                #expect(cell.bubbleView.waveformView.progress == 0.5)
                var plainAudio = audio
                plainAudio.transcript = nil
                configure(cell, audio: plainAudio, direction: direction)
                layout(cell, width: 402)
                #expect(cell.bubbleView.transcriptLabel.superview == nil)
                #expect(abs(cell.bounds.height - plainHeight) < 1)
                configure(cell, audio: audio, direction: direction)
                layout(cell, width: 402)
                #expect(cell.bubbleView.transcriptLabel.isDescendant(of: cell.bubbleView))
                cell.prepareForReuse()
                layout(cell, width: 402)
                #expect(cell.bubbleView.transcriptLabel.text == nil)
                #expect(cell.bubbleView.transcriptLabel.superview == nil)
                configure(cell, audio: fixtureAudio(), direction: direction)
                layout(cell, width: 402)
                #expect(cell.bubbleView.transcriptLabel.superview == nil)
                #expect(abs(cell.bounds.height - plainHeight) < 1)
                configure(cell, audio: audio, direction: direction)
                layout(cell, width: 402)
                #expect(cell.bubbleView.transcriptLabel.isDescendant(of: cell.bubbleView))
                #expect(!cell.bubbleView.transcriptLabel.isHidden)
                #expect(cell.bubbleView.transcriptLabel.text == audio.transcript)
            }
        }
    }

    @Test func messageAndPreviewTimeCountUpPauseAndReplayTogether() {
        guard #available(iOS 26.0, *) else { return }
        let audio = AudioAttachment(
            fileURL: URL(fileURLWithPath: "/tmp/countdown.caf"), duration: 10,
            waveform: fixtureAudio().waveform, transcript: "保留转写文本"
        )
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 402, height: 80))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        for direction in [MessageDirection.incoming, .outgoing] {
            let cell = AudioBubbleCell(frame: .zero)
            configure(cell, audio: audio, direction: direction)
            #expect(cell.bubbleView.durationLabel.text == "00:10")
            cell.updatePlayback(.init(messageID: 8, attachmentID: audio.id, isPlaying: true, progress: 0.5), playAccessibilityLabel: "播放", pauseAccessibilityLabel: "暂停")
            #expect(cell.bubbleView.playButton.accessibilityLabel == "播放")
            #expect(cell.bubbleView.waveformView.progress == 0)
            for (playing, progress, expected, elapsed) in [
                (true, 0.0, "00", "00"), (true, 0.19, "01", "01"),
                (false, 0.3, "03", "03"), (true, 0.5, "05", "05"),
                (true, 1.0, "10", "10"), (false, 1.0, "10", "10"),
                (true, 0.0, "00", "00")
            ] {
                cell.updatePlayback(.init(messageID: 7, attachmentID: audio.id, isPlaying: playing, progress: progress), playAccessibilityLabel: "播放", pauseAccessibilityLabel: "暂停")
                composer.applyState(.audioPreview(attachment: audio, isPlaying: playing, progress: progress))
                #expect(cell.bubbleView.durationLabel.text == "00:\(expected)")
                #expect(composer.previewDurationLabel.text == "00:\(expected)")
                #expect(cell.bubbleView.playButton.accessibilityValue == "00:\(elapsed) / 00:10")
                #expect(composer.audioPlayButton.accessibilityValue == "00:\(elapsed) / 00:10")
                #expect(cell.bubbleView.transcriptLabel.text == audio.transcript)
            }
            cell.updatePlayback(.init(messageID: 8, attachmentID: UUID(), isPlaying: true, progress: 0.5), playAccessibilityLabel: "播放", pauseAccessibilityLabel: "暂停")
            #expect(cell.bubbleView.durationLabel.text == "00:10")
        }
    }

    @Test func switchingMessagesStopsPreviousBeforeStartingNext() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let url = store.makeFileURL(prefix: "exclusive-playback", pathExtension: "caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let first = AudioAttachment(fileURL: url, duration: 10, waveform: fixtureAudio().waveform)
        let second = AudioAttachment(fileURL: url, duration: 10, waveform: fixtureAudio().waveform)
        let media = AudioController(attachmentStore: store)
        defer { media.stopAll(); store.removeAll() }
        var states: [PlaybackState] = []
        media.playbackDidChange = { states.append($0) }
        media.toggleMessagePlayback(messageID: 1, attachment: first)
        #expect(await eventually { media.playbackState.progress > 0.05 })
        states.removeAll()
        media.toggleMessagePlayback(messageID: 2, attachment: second)
        let stopped = try #require(states.firstIndex { $0.messageID == 1 && !$0.isPlaying })
        // 原目标同步停止，新目标等待音频会话及播放器在后台准备完成。
        #expect(await eventually { media.playbackState.messageID == 2 && media.playbackState.isPlaying })
        let started = try #require(states.firstIndex { $0.messageID == 2 && $0.isPlaying })
        #expect(stopped < started)
        #expect(states[stopped].progress == 0)
        #expect(media.playbackState.attachmentID == second.id)
        #expect(await eventually { media.playbackState.progress > 0.05 })
        media.toggleMessagePlayback(messageID: 2, attachment: second)
        let paused = media.playbackState.progress
        #expect(!media.playbackState.isPlaying)
        media.toggleMessagePlayback(messageID: 2, attachment: second)
        #expect(await eventually { media.playbackState.isPlaying })
        // AVAudioPlayer 恢复时的硬件采样位置可回退少量帧，不能退回文件起点。
        #expect(media.playbackState.progress >= paused - 0.005)
        #expect(await eventually { media.playbackState.progress > paused })
    }

    @Test func audioGeometryMatchesNativeMessageReferenceAtDefaultTextSize() {
        guard #available(iOS 26.0, *) else { return }
        let cell = AudioBubbleCell(frame: .zero)
        cell.bubbleView.traitOverrides.preferredContentSizeCategory = .large
        var audio = fixtureAudio()
        configure(cell, audio: audio, direction: .outgoing)
        layout(cell, width: 402)
        let bubble = cell.bubbleView
        #expect(abs(bubble.bounds.width - 281.4) < 1)
        #expect(abs(bubble.bounds.height - 82) < 1)
        #expect(bubble.durationLabel.font.pointSize == 15)
        let play = bubble.playButton.frame
        let wave = bubble.waveformView.frame
        let duration = bubble.durationLabel.frame
        #expect(abs(play.midY - 38) < 1)
        #expect(abs(wave.minX - 56) < 1)
        #expect(abs(duration.minX - wave.maxX - 12) < 1)
        #expect(abs(bubble.bounds.width - duration.maxX - 14) < 1)
        #expect(bubble.waveformView.unplayedColor == .white)
        #expect(bubble.backgroundColor == AudioBubbleView.audioBlue)
        audio.transcript = "你好，你吃饭了吗？"
        configure(cell, audio: audio, direction: .incoming)
        layout(cell, width: 402)
        let transcript = bubble.transcriptLabel.frame
        #expect(abs(transcript.minX - 18) < 1)
        #expect(abs(transcript.minY - 66) < 1)
        #expect(bubble.transcriptLabel.font.pointSize == 15)
        #expect(bubble.bounds.height > 100 && bubble.bounds.height < 110)
    }

    @Test func controllerPreservesKeyboardDraftAndActivePlaybackWhenTextArrives() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let store = PageAttachmentStore()
        let url = store.makeFileURL(prefix: "playback-transcript", pathExtension: "caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let audio = AudioAttachment(fileURL: url, duration: 10, waveform: fixtureAudio().waveform)
        store.registerCommitted(.audio(audio))
        let model = makeModel()
        let media = AudioController(attachmentStore: store)
        let transcriber = ControlledFileTranscriber()
        let controller = ChatViewController(viewModel: model, audioController: media, audioFileTranscriber: transcriber)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.composerView.textView.resignFirstResponder()
            model.cancelPendingReply()
            media.stopAll()
            store.removeAll()
            window.isHidden = true
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        let editor = controller.composerView.textView
        editor.text = "保留正在输入的草稿"
        #expect(editor.becomeFirstResponder())
        #expect(await eventually { controller.view.keyboardLayoutGuide.layoutFrame.height > 100 })
        #expect(model.sendAttachment(.audio(audio)))
        #expect(await eventually { transcriber.calls.count == 1 })
        let message = try #require(audioMessages(model.state).last)
        media.toggleMessagePlayback(messageID: message.id, attachment: audio)
        #expect(await eventually { media.playbackState.isPlaying && media.playbackState.progress > 0 })
        let progress = media.playbackState.progress
        transcriber.resolve(.success("你好，你吃饭了吗？"))
        #expect(await eventually {
            controller.conversationView.collectionView.visibleCells.contains {
                ($0 as? AudioBubbleCell)?.bubbleView.transcriptLabel.text == "你好，你吃饭了吗？"
            }
        })
        #expect(media.playbackState.isPlaying)
        #expect(media.playbackState.progress >= progress)
        #expect(await eventually {
            controller.conversationView.collectionView.visibleCells.contains {
                ($0 as? AudioBubbleCell)?.bubbleView.durationLabel.text == "00:01"
            }
        })
        #expect(media.playbackState.attachmentID == audio.id)
        #expect(editor.isFirstResponder)
        #expect(editor.text == "保留正在输入的草稿")
        #expect(controller.view.keyboardLayoutGuide.layoutFrame.height > 100)
    }

    @Test func listResizesInPlacePreservesHistoryAnchorAndFollowsBottom() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let conversation = ConversationView(frame: .zero)
        root.view = conversation
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        root.view.layoutIfNeeded()
        var audios = (0..<24).map { _ in fixtureAudio() }
        func state() -> ChatViewModel.State {
            .init(timeline: audios.enumerated().map { index, audio in
                .init(id: .message(index), content: .message(.init(id: index, direction: .outgoing, attachment: .audio(audio), deliveryText: nil)))
            }, isTyping: false)
        }
        conversation.render(state(), reason: .initial)
        #expect(await eventually { conversation.collectionView.cellForItem(at: IndexPath(item: 23, section: 0)) != nil })
        let collection = conversation.collectionView
        collection.scrollToItem(at: IndexPath(item: 8, section: 0), at: .top, animated: false)
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 8, section: 0)))
        let before = cell.convert(cell.bounds, to: window).minY
        let oldHeight = cell.bounds.height
        audios[4].transcript = String(repeating: "历史音频识别出的内容。", count: 15)
        audios[8].transcript = String(repeating: "正在阅读的这条消息。", count: 10)
        conversation.render(state(), reason: .audioTranscript)
        #expect(await eventually {
            guard let cell = collection.cellForItem(at: IndexPath(item: 8, section: 0)) else { return false }
            return cell.bounds.height > oldHeight + 40
        })
        try await Task.sleep(nanoseconds: 150_000_000)
        let updated = try #require(collection.cellForItem(at: IndexPath(item: 8, section: 0)))
        #expect(abs(updated.convert(updated.bounds, to: window).minY - before) < 2)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "audio-transcript-history-anchor.png")
        conversation.scrollToBottom(animated: false)
        collection.layoutIfNeeded()
        audios[23].transcript = String(repeating: "最后一条音频消息。", count: 10)
        conversation.render(state(), reason: .audioTranscript)
        #expect(await eventually {
            guard let cell = collection.cellForItem(at: IndexPath(item: 23, section: 0)) as? AudioBubbleCell else { return false }
            return cell.bubbleView.transcriptLabel.text == audios[23].transcript
        })
        try await Task.sleep(nanoseconds: 150_000_000)
        let last = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 23, section: 0)))
        let bottom = last.frame.maxY + collection.adjustedContentInset.bottom - collection.bounds.height
        #expect(abs(collection.contentOffset.y - bottom) < 2)
    }

    @Test func referenceBubbleSnapshotsAndLargeTextHaveNoClipping() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        root.traitOverrides.preferredContentSizeCategory = .large
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let width = window.bounds.width
        var y: CGFloat = 60
        for (index, direction) in [MessageDirection.incoming, .incoming, .incoming, .outgoing, .outgoing, .outgoing].enumerated() {
            var audio = fixtureAudio()
            if index % 3 == 1 { audio.transcript = "你好，你吃饭了吗？" }
            if index % 3 == 2 { audio.transcript = "这是一条分行显示的音频转写，文字会完整保留，播放时也不会消失。" }
            let cell = AudioBubbleCell(frame: .zero)
            root.view.addSubview(cell)
            configure(cell, audio: audio, direction: direction)
            layout(cell, width: width)
            cell.frame.origin.y = y
            y += cell.bounds.height + 16
        }
        root.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-transcript-iphone16pro.png")
        try image.pngData()?.write(to: url)
        logger.notice("AUDIO_TRANSCRIPT_SNAPSHOT: \(url.path, privacy: .public)")
        root.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        #expect(await eventually { root.view.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge })
        let cell = AudioBubbleCell(frame: .zero)
        root.view.addSubview(cell)
        var audio = fixtureAudio()
        audio.transcript = String(repeating: "مرحبا كيف حالك اليوم؟ ", count: 8)
        cell.semanticContentAttribute = .forceRightToLeft
        configure(cell, audio: audio, direction: .incoming)
        layout(cell, width: 320)
        let bubble = cell.bubbleView
        #expect(await eventually { bubble.transcriptLabel.font.pointSize > 15 })
        layout(cell, width: 320)
        #expect(bubble.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(bubble.durationLabel.bounds.width > 0)
        #expect(bubble.waveformView.bounds.width > 0)
        let text = bubble.transcriptLabel.convert(bubble.transcriptLabel.bounds, to: bubble)
        #expect(text.minX >= 0 && text.maxX <= bubble.bounds.width + 1)
        #expect(text.maxY <= bubble.bounds.height - 6)
        let expected = bubble.transcriptLabel.sizeThatFits(CGSize(width: text.width, height: .greatestFiniteMagnitude))
        #expect(text.height >= expected.height - 1)
    }

    @available(iOS 26.0, *)
    private func makeModel() -> ChatViewModel {
        ChatViewModel(localizer: Localizer { key, _ in key }, clock: Date.init,
                             sleeper: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
    }

    @available(iOS 26.0, *)
    private func makeCoordinator(_ model: ChatViewModel, _ transcriber: ControlledFileTranscriber) -> AudioTranscriptionCoordinator {
        AudioTranscriptionCoordinator(transcriber: transcriber) { [weak model] id, attachmentID, text in
            model?.updateAudioTranscript(text, messageID: id, attachmentID: attachmentID)
        }
    }

    @available(iOS 26.0, *)
    private func audioMessages(_ state: ChatViewModel.State) -> [MessagePresentation] {
        state.timeline.compactMap {
            guard case .message(let message) = $0.content, message.audio != nil else { return nil }
            return message
        }
    }

    @available(iOS 26.0, *)
    private func makeAudio() throws -> AudioAttachment {
        let audio = fixtureAudio()
        try Data([0]).write(to: audio.fileURL)
        return audio
    }

    @available(iOS 26.0, *)
    private func fixtureAudio() -> AudioAttachment {
        .init(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a"),
              duration: 2, waveform: (0..<48).map { Float(($0 * 7) % 13 + 1) / 14 })
    }

    @available(iOS 26.0, *)
    private func configure(_ cell: AudioBubbleCell, audio: AudioAttachment, direction: MessageDirection) {
        cell.configure(.init(id: 7, direction: direction, attachment: .audio(audio), deliveryText: direction == .outgoing ? "已读" : nil),
                       playback: .idle, playAccessibilityLabel: "播放", pauseAccessibilityLabel: "暂停")
    }

    @available(iOS 26.0, *)
    private func layout(_ cell: AudioBubbleCell, width: CGFloat) {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: width, height: 52)
        cell.frame = CGRect(origin: .zero, size: cell.preferredLayoutAttributesFitting(attributes).size)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    @available(iOS 26.0, *)
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@available(iOS 26.0, *)
@MainActor
private final class ControlledFileTranscriber: AudioFileTranscribing {
    struct Call { let url: URL; let locale: Locale }
    var calls: [Call] = []
    private var pending: CheckedContinuation<String?, any Error>?
    func transcribe(fileURL: URL, locale: Locale) async throws -> String? {
        calls.append(Call(url: fileURL, locale: locale))
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func resolve(_ result: Result<String?, any Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@available(iOS 26.0, *)
@MainActor
private final class ReplySynthesizer: ReplyAudioSynthesizing {
    let audio: AudioAttachment
    init(audio: AudioAttachment) { self.audio = audio }
    func synthesizeReplyAudio(text: String, locale: Locale) async throws -> AudioAttachment { audio }
}

@available(iOS 26.0, *)
@MainActor
private final class DeniedFilePermissions: MediaPermissionProviding {
    var speechRequests = 0
    var microphoneRequests = 0
    func requestSpeechPermission() async -> Bool { speechRequests += 1; return false }
    func requestMicrophonePermission() async -> Bool { microphoneRequests += 1; return false }
}
