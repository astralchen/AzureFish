//
//  AudioController+AudioSession.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 协调音频会话、中断和后台清理。
@available(iOS 26.0, *)
extension AudioController {

    /// 获取所有权后异步激活采集；等待期间停止操作会使本次结果失效。
    func configureCaptureSession() async throws {
        try await configureAudioSession(capture: true)
    }

    /// 获取所有权后异步激活播放；旧任务不能在所有权转移后重新出声。
    func configurePlaybackSession() async throws {
        try await configureAudioSession(capture: false)
    }

    /// 预先登记正在激活的会话占用，使停止操作可以立即排入对应的停用请求。
    private func configureAudioSession(capture: Bool) async throws {
        try Task.checkCancellation()
        playbackCoordinator.acquire(owner: playbackOwner) { [weak self] in self?.stopAll() }
        audioSessionGeneration += 1
        let generation = audioSessionGeneration
        ownsAudioSession = true
        do {
            if capture { try await audioSession.activateCapture() }
            else { try await audioSession.activatePlayback() }
            try Task.checkCancellation()
            guard audioSessionGeneration == generation else { throw CancellationError() }
        } catch {
            if audioSessionGeneration == generation { finishAudioSession() }
            throw error
        }
    }

    /// 在录音和播放均不占用设备时释放会话；停用先入队，再允许新所有者接管。
    func finishAudioSession() {
        guard recorder == nil, player?.isPlaying != true else { return }
        audioSessionGeneration += 1
        playbackCoordinator.release(owner: playbackOwner)
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        audioSession.deactivate()
    }

    /// 订阅会话中断、输出设备移除和应用后台事件，以停止或暂停对应操作。
    func observeAudioLifecycle() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession.notificationObject,
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue)
                    == .began else { return }
            // 在通知回调内解析载荷，主 Actor 边界只处理控制器，不传递非 Sendable 的 Notification。
            MainActor.assumeIsolated { self?.handleCaptureInterruption() }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession.notificationObject,
            queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue)
                    == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pausePlayback() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopAll()
            }
        }
    }

    /// 响应音频中断，保留有效录音、结束听写并暂停播放。
    private func handleCaptureInterruption() {
        if recorder != nil {
            finishRecording(keepValidRecording: true)
            return
        }
        if case .dictating = state {
            stopDictation()
        } else if state == .preparingSpeech {
            stopDictation()
        }
        pausePlayback()
    }
}
