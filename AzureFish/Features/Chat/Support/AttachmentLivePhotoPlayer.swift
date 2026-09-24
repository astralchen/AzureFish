import AVFoundation
import PhotosUI
import UIKit

/// 只负责单页实况的重建与播放；图片几何和本次预览的开关选择由外部持有。
@MainActor
final class AttachmentLivePhotoPlayer: NSObject, PHLivePhotoViewDelegate {
    let view = PHLivePhotoView()
    let effect = LivePhotoMotionEffect()
    private var effectTask: Task<Void, Never>?
    private var mode: LivePhotoPlaybackMode = .live
    var didFail: (() -> Void)?
    private let coordinator: PlaybackCoordinator
    private let audioSession: AudioSessionControlling
    private let owner = UUID()
    private var requestID: PHLivePhotoRequestID?
    private var generation = UUID()
    private var preparedPhoto: URL?
    private var activationTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private var ownsSession = false
    private var observers: [NSObjectProtocol] = []
    private(set) var isPlaying = false
    var isReady: Bool { view.livePhoto != nil }

    init(coordinator: PlaybackCoordinator, audioSession: AudioSessionControlling? = nil) {
        self.coordinator = coordinator
        self.audioSession = audioSession ?? SystemAudioSessionController()
        super.init()
        view.delegate = self
        view.contentMode = .scaleAspectFit
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.playbackGestureRecognizer.isEnabled = false
        for name in [UIApplication.willResignActiveNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.routeChangeNotification,
                   (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }

    /// 一个激活周期只请求一次；关闭实况或离屏会取消请求，重新开启可重试失败资源。
    func prepare(photo: URL, video: URL, placeholder: UIImage?, targetSize: CGSize) {
        guard preparedPhoto != photo else { return }
        unload()
        mode = .live
        preparedPhoto = photo
        let token = generation
        requestID = PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: placeholder,
                                       targetSize: targetSize, contentMode: .aspectFit) { [weak self] livePhoto, info in
            let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true
            let cancelled = (info[PHLivePhotoInfoCancelledKey] as? Bool) == true
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !degraded, !cancelled else { return }
                self.requestID = nil
                self.view.livePhoto = livePhoto
                if livePhoto == nil { self.didFail?() }
            }
        }
    }

    /// 连续效果静音；仍取得页面播放权，避免与语音或视频同时运行。
    func playEffect(video: URL, mode: LivePhotoPlaybackMode, targetSize: CGSize) {
        guard mode.isContinuous, UIApplication.shared.applicationState != .background else { return }
        stop()
        self.mode = mode
        coordinator.acquire(owner: owner) { [weak self] in self?.stop() }
        let token = playbackGeneration
        effectTask = Task { [weak self] in
            do {
                let frames = try await LivePhotoMotionFrames.load(video: video, targetSize: targetSize)
                guard let self, !Task.isCancelled, playbackGeneration == token,
                      UIApplication.shared.applicationState != .background else { return }
                effectTask = nil
                effect.start(frames: frames, mode: mode)
                isPlaying = true
            } catch {
                guard let self, !Task.isCancelled, playbackGeneration == token else { return }
                stop()
                didFail?()
            }
        }
    }

    /// 长按取得播放权后异步激活音频，松手或离屏使迟到激活失效。
    func play() {
        guard mode == .live, isReady, !isPlaying, activationTask == nil,
              UIApplication.shared.applicationState != .background else { return }
        coordinator.acquire(owner: owner) { [weak self] in self?.stop() }
        let token = UUID()
        playbackGeneration = token
        ownsSession = true
        activationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await audioSession.activatePreviewPlayback()
                guard !Task.isCancelled, playbackGeneration == token, isReady else { return }
                activationTask = nil
                view.isMuted = false
                view.startPlayback(with: .full)
            } catch {
                guard playbackGeneration == token, !Task.isCancelled else { return }
                stop()
                didFail?()
            }
        }
    }

    func stop() {
        playbackGeneration = UUID()
        activationTask?.cancel()
        activationTask = nil
        effectTask?.cancel()
        effectTask = nil
        effect.stop()
        view.stopPlayback()
        finishPlayback()
    }

    private func finishPlayback() {
        isPlaying = false
        view.isHidden = true
        if ownsSession {
            ownsSession = false
            audioSession.deactivate()
        }
        coordinator.release(owner: owner)
    }

    func unload() {
        generation = UUID()
        if let requestID { PHLivePhoto.cancelRequest(withRequestID: requestID) }
        requestID = nil
        preparedPhoto = nil
        stop()
        view.livePhoto = nil
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        guard mode == .live else { return }
        isPlaying = true
        view.isHidden = false
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        guard mode == .live else { return }
        finishPlayback()
    }

    isolated deinit {
        if let requestID { PHLivePhoto.cancelRequest(withRequestID: requestID) }
        activationTask?.cancel()
        effectTask?.cancel()
        if ownsSession { audioSession.deactivate() }
        coordinator.release(owner: owner)
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
