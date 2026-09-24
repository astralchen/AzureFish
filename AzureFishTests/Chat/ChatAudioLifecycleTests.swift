import AVFAudio
import AVKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatAudioLifecycleTests {
    @Test func coveringChatStopsPlaybackButOnlyPoppingChatDeletesAttachments() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        let chat = fixture.makeChat()
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.setViewControllers([navigation.viewControllers[0], chat], animated: false)
        let host = try WindowHost(root: navigation)
        defer { fixture.clean(); host.close() }
        #expect(await eventually { chat.view.window != nil })
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            chat.present(cover, animated: false) { continuation.resume() }
        }
        #expect(fixture.media.playbackState == .idle)
        #expect(fixture.fileExists)
        await withCheckedContinuation { continuation in
            cover.dismiss(animated: false) { continuation.resume() }
        }
        #expect(fixture.media.playbackState == .idle)
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.isPlaying })
        navigation.pushViewController(UIViewController(), animated: false)
        #expect(await eventually { fixture.media.playbackState == .idle })
        #expect(fixture.fileExists)
        navigation.popViewController(animated: false)
        #expect(await eventually { navigation.topViewController === chat && chat.view.window != nil })
        // UIKit 即使不带动画也会异步提交导航切换，完成后再发起下一次返回。
        try await Task.sleep(nanoseconds: 100_000_000)
        fixture.play()
        navigation.popViewController(animated: false)
        #expect(await eventually { !fixture.fileExists })
        #expect(fixture.media.playbackState == .idle)
    }

    @Test func changingTabsStopsPlaybackWithoutDiscardingChat() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        let chat = fixture.makeChat()
        let tabs = UITabBarController()
        tabs.viewControllers = [UINavigationController(rootViewController: chat), UIViewController()]
        let host = try WindowHost(root: tabs)
        defer { fixture.clean(); host.close() }
        #expect(await eventually { chat.view.window != nil })
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        tabs.selectedIndex = 1
        #expect(await eventually { fixture.media.playbackState == .idle })
        #expect(fixture.fileExists)
        tabs.selectedIndex = 0
        #expect(await eventually { chat.view.window != nil })
        #expect(fixture.media.playbackState == .idle)
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.isPlaying })
    }

    @Test func dismissingParentContainerCleansUpChat() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        let root = UIViewController()
        let host = try WindowHost(root: root)
        defer { fixture.clean(); host.close() }
        let navigation = UINavigationController(rootViewController: fixture.makeChat())
        navigation.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            root.present(navigation, animated: false) { continuation.resume() }
        }
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
        #expect(fixture.media.playbackState == .idle)
        #expect(!fixture.fileExists)
    }

    @Test func backgroundResetsPlaybackWithoutDeletingFileOrAutoResuming() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(fixture.media.playbackState == .idle)
        #expect(fixture.fileExists)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(fixture.media.playbackState == .idle)
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.isPlaying })
    }

    @Test func interruptionsAndDisconnectedOutputPauseWithoutAutoResuming() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(!fixture.media.playbackState.isPlaying)
        #expect(fixture.media.playbackState.progress > 0)
        #expect(fixture.media.playbackState.attachmentID == fixture.audio.id)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        #expect(!fixture.media.playbackState.isPlaying)
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.isPlaying })
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        #expect(!fixture.media.playbackState.isPlaying)
        #expect(fixture.media.playbackState.progress > 0)
        #expect(fixture.fileExists)
    }

    @Test func startingCaptureResetsPlaybackEvenWhenPermissionIsDenied() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        fixture.media.startRecording()
        #expect(fixture.media.playbackState == .idle)
        await Task.yield()
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        fixture.media.startDictation(locale: Locale(identifier: "zh-CN"))
        #expect(fixture.media.playbackState == .idle)
        #expect(fixture.fileExists)
    }

    @Test func losingPlaybackFileStopsAndReportsFailureOnce() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        defer { fixture.clean() }
        var failureCount = 0
        fixture.media.failureDidOccur = { _ in failureCount += 1 }
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        fixture.store.removeFile(at: fixture.audio.fileURL)
        #expect(await eventually { fixture.media.playbackState == .idle })
        #expect(failureCount == 1)
    }

    @Test func idleAudioControllerDoesNotDeactivateAnotherMediaSession() async throws {
        guard #available(iOS 26.0, *) else { return }
        let session = CountingSession()
        let fixture = try Fixture(audioSession: session)
        defer { fixture.clean() }
        fixture.media.stopPlayback()
        fixture.media.stopAll()
        #expect(session.deactivationCount == 0)
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.isPlaying })
        #expect(session.activationCount == 1)
        fixture.media.stopPlayback()
        #expect(session.deactivationCount == 1)
        // 视频接管后，聊天页重复退出或后台通知都不能再次释放共享会话。
        fixture.media.stopPlayback()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(session.deactivationCount == 1)
    }

    @Test func videoAndAudioAreMutuallyExclusiveAcrossInlinePlaybackAndBackground() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try Fixture()
        let url = try await makeVideo(in: fixture.store)
        let item = MediaItem(assetIdentifier: nil, originalFileURL: url,
                                        thumbnailFileURL: url, pixelSize: CGSize(width: 64, height: 48),
                                        kind: .video(duration: 10))
        let preview = AttachmentPreviewController(
            items: AttachmentPreviewItem.prepare(.mediaGroup(.init(items: [item]))),
            initialIndex: 0, playbackCoordinator: fixture.media.playbackCoordinator)
        let host = try WindowHost(root: preview)
        defer { fixture.clean(); host.close() }
        #expect(await eventually { preview.playback.isPlaying })
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.progress > 0 })
        preview.chrome.playbackControls.playButton.sendActions(for: .touchUpInside)
        #expect(await eventually { preview.playback.player?.rate == 1 })
        #expect(fixture.media.playbackState == .idle)
        let player = try #require(preview.playback.player)
        #expect(await eventually { preview.playback.duration > 0 })
        preview.playback.beginSeeking()
        preview.playback.beginSeeking() // Duplicate touch-down must not replace the original playback intent.
        preview.playback.seek(fraction: 0.3, finished: true)
        preview.playback.seek(fraction: 0.5, finished: true)
        preview.playback.seek(fraction: 0.5, finished: false) // iOS 26 slider settling may deliver valueChanged after touch-up.
        #expect(await eventually { preview.playback.isPlaying && preview.playback.time >= 4.9 })
        #expect(preview.presentedViewController == nil)
        #expect(AVAudioSession.sharedInstance().category == .playback)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(player.rate == 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(player.rate == 0)
        preview.chrome.playbackControls.playButton.sendActions(for: .touchUpInside)
        #expect(await eventually { player.rate == 1 })
        fixture.play()
        #expect(await eventually { fixture.media.playbackState.isPlaying })
        #expect(player.rate == 0)
        #expect(preview.playback.player == nil)
        #expect(fixture.fileExists)
        preview.chrome.playbackControls.playButton.sendActions(for: .touchUpInside)
        #expect(await eventually { preview.playback.player?.rate == 1 })
        #expect(fixture.media.playbackState == .idle)
        let nextPlayer = try #require(preview.playback.player)
        preview.completeDismissal()
        #expect(nextPlayer.rate == 0)
        #expect(preview.playback.player == nil)
        #expect(fixture.media.playbackState == .idle)
    }

    /// 激活尚未结束时停止，迟到成功不能启动已退出页面的音频。
    @Test func stoppingWhileAudioSessionActivatesDoesNotStartPlayback() async throws {
        guard #available(iOS 26.0, *) else { return }
        let session = DelayedAudioSession()
        let fixture = try Fixture(audioSession: session)
        defer { fixture.clean() }
        fixture.play()
        #expect(await eventually { session.pending.count == 1 })
        let task = fixture.media.playbackTask.currentTask
        fixture.media.stopAll()
        #expect(session.deactivationCount == 1)
        session.completeFirst()
        await task?.value
        #expect(fixture.media.player == nil)
        #expect(fixture.media.playbackState == .idle)
        #expect(!fixture.media.ownsAudioSession)
        #expect(session.deactivationCount == 1)
    }

    /// 旧激活失败不能清理后来重新申请的会话或触发错误提示。
    @Test func staleActivationFailureCannotReleaseNewPlaybackRequest() async throws {
        guard #available(iOS 26.0, *) else { return }
        let session = DelayedAudioSession()
        let fixture = try Fixture(audioSession: session)
        defer { fixture.clean() }
        var failures = 0
        fixture.media.failureDidOccur = { _ in failures += 1 }
        fixture.play()
        #expect(await eventually { session.pending.count == 1 })
        let oldTask = fixture.media.playbackTask.currentTask
        fixture.media.stopPlayback()
        fixture.play()
        #expect(await eventually { session.pending.count == 2 })
        let newTask = fixture.media.playbackTask.currentTask
        session.completeFirst(error: CocoaError(.fileReadUnknown))
        await oldTask?.value
        #expect(fixture.media.ownsAudioSession)
        #expect(session.deactivationCount == 1)
        #expect(failures == 0)
        fixture.media.stopAll()
        session.completeFirst()
        await newTask?.value
        #expect(session.deactivationCount == 2)
        #expect(fixture.media.player == nil)
    }

    /// 录音和听写等待会话时退出，不能在系统回调到达后启动麦克风。
    @Test(arguments: [false, true])
    func stoppingPendingCapturePreventsRecorderAndTranscriberStart(dictation: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let session = DelayedAudioSession()
        let speech = NoSpeech()
        let media = AudioController(audioSession: session, fileManager: .default,
                                               speechTranscriber: speech, permissionProvider: GrantedPermissions())
        defer { media.stopAll(); media.attachmentStore.removeAll() }
        if dictation { media.startDictation(locale: Locale(identifier: "en-US")) }
        else { media.startRecording() }
        #expect(await eventually { session.pending.count == 1 })
        let task = media.operationTask
        if dictation { media.stopDictation() } else { media.stopRecording() }
        session.completeFirst()
        await task?.value
        #expect(media.recorder == nil)
        #expect(speech.startCount == 0)
        #expect(media.state == .idle)
        #expect(session.deactivationCount == 1)
    }

    /// 预览激活期间暂停或停止，迟到成功和失败都不能重新出声。
    @Test(arguments: [false, true])
    func cancellingPreviewActivationPreventsLatePlayback(stop: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let session = DelayedAudioSession()
        let fixture = try Fixture()
        let preview = AttachmentPreviewPlayer(coordinator: fixture.media.playbackCoordinator, audioSession: session)
        defer { preview.stop(); fixture.clean() }
        preview.prepare(url: fixture.audio.fileURL)
        preview.toggle()
        #expect(await eventually { session.pending.count == 1 })
        let task = preview.activationTask
        if stop { preview.stop() } else { preview.pause() }
        session.completeFirst()
        await task?.value
        #expect(!preview.isPlaying)
        #expect(preview.activationTask == nil)
        #expect(session.deactivationCount == 1)
    }

    /// 等待激活期间开始拖动，系统完成后仍保持暂停，由 seek 收尾决定恢复。
    @Test func seekingDuringPreviewActivationDoesNotStartPlaybackEarly() async throws {
        guard #available(iOS 26.0, *) else { return }
        let session = DelayedAudioSession()
        let fixture = try Fixture()
        let preview = AttachmentPreviewPlayer(coordinator: fixture.media.playbackCoordinator, audioSession: session)
        defer { preview.stop(); fixture.clean() }
        preview.prepare(url: fixture.audio.fileURL)
        preview.toggle()
        #expect(await eventually { session.pending.count == 1 })
        let task = preview.activationTask
        preview.beginSeeking()
        session.completeFirst()
        await task?.value
        #expect(preview.isSeeking)
        #expect(!preview.isPlaying)
        preview.pause()
        #expect(session.deactivationCount == 1)
    }

    @available(iOS 26.0, *)
    private func makeVideo(in store: PageAttachmentStore) async throws -> URL {
        let url = store.makeFileURL(prefix: "lifecycle-video", pathExtension: "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x7f, CVPixelBufferGetBytesPerRow(pixels) * 48)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try #require(input.isReadyForMoreMediaData && writer.status == .writing)
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame * 5), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 10, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @available(iOS 26.0, *)
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }
}

@available(iOS 26.0, *)
@MainActor
private final class Fixture {
    let store = PageAttachmentStore()
    let audio: AudioAttachment
    let media: AudioController
    let model: ChatViewModel

    init(audioSession: AudioSessionControlling? = nil) throws {
        model = ChatViewModel(localizer: Localizer { key, _ in key }, clock: Date.init,
                              sleeper: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let url = store.makeFileURL(prefix: "lifecycle", pathExtension: "caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        audio = .init(fileURL: url, duration: 10, waveform: [0.2, 0.5, 0.8], transcript: "测试附件")
        media = AudioController(audioSession: audioSession ?? SystemAudioSessionController(),
                                           fileManager: .default, speechTranscriber: NoSpeech(),
                                           permissionProvider: DeniedPermissions(), attachmentStore: store)
        store.registerCommitted(.audio(audio))
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: audio.fileURL.path) }
    func play() { media.toggleMessagePlayback(messageID: 1, attachment: audio) }
    func makeChat() -> ChatViewController {
        _ = model.sendAttachment(.audio(audio))
        return ChatViewController(viewModel: model, audioController: media)
    }
    func clean() { media.stopAll(); model.cancelPendingReply(); store.removeAll() }
}

@available(iOS 26.0, *)
@MainActor
private final class CountingSession: AudioSessionControlling {
    let notificationObject: AnyObject = NSObject()
    var activationCount = 0
    var deactivationCount = 0
    func activateCapture() async throws { activationCount += 1 }
    func activatePlayback() async throws { activationCount += 1 }
    func activatePreviewPlayback() async throws { try await activatePlayback() }

    func deactivate() { deactivationCount += 1 }
}

@available(iOS 26.0, *)
@MainActor
private struct WindowHost {
    let window: UIWindow
    let previous: UIWindow?
    init(root: UIViewController) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
    }
    func close() { window.isHidden = true; previous?.makeKey() }
}

@available(iOS 26.0, *)
@MainActor
private final class DeniedPermissions: MediaPermissionProviding {
    func requestMicrophonePermission() async -> Bool { false }
    func requestSpeechPermission() async -> Bool { false }
}

@available(iOS 26.0, *)
@MainActor
private final class NoSpeech: SpeechTranscribing {
    var startCount = 0
    func start(locale: Locale, result: @escaping @MainActor (String, Bool) -> Void,
               failure: @escaping @MainActor () -> Void) async throws { startCount += 1 }
    func stop() {}
}

/// 保持激活挂起，测试主动控制系统完成时机和成功或失败结果。
@available(iOS 26.0, *)
@MainActor
private final class DelayedAudioSession: AudioSessionControlling {
    /// 测试专用通知对象，不订阅真实系统会话。
    let notificationObject: AnyObject = NSObject()
    /// 尚未完成的激活请求，按调用顺序保存。
    var pending: [CheckedContinuation<Void, Error>] = []
    /// 已同步提交的停用次数。
    var deactivationCount = 0
    /// 挂起采集激活。
    func activateCapture() async throws { try await activatePlayback() }
    /// 挂起播放激活。
    func activatePlayback() async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    /// 挂起预览激活。
    func activatePreviewPlayback() async throws { try await activatePlayback() }
    /// 记录停用请求。
    func deactivate() { deactivationCount += 1 }
    /// 完成最早的激活请求，允许模拟系统错误。
    func completeFirst(error: Error? = nil) {
        guard !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

/// 只在取消测试中放行权限；测试会在激活完成之前停止，不启动真实麦克风。
@available(iOS 26.0, *)
@MainActor
private final class GrantedPermissions: MediaPermissionProviding {
    /// 允许测试进入采集会话等待阶段。
    func requestMicrophonePermission() async -> Bool { true }
    /// 允许测试进入听写会话等待阶段。
    func requestSpeechPermission() async -> Bool { true }
}
