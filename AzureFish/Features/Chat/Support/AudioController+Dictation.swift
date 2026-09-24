//
//  AudioController+Dictation.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 管理实时听写与迟到结果过滤。
@available(iOS 26.0, *)
extension AudioController {

    /// 请求所需权限并开始实时语音转写。
    ///
    /// - Parameter locale: 用于选择识别语言的区域设置。
    func startDictation(locale: Locale) {
        guard state == .idle else { return }
        stopPlayback()
        playbackCoordinator.acquire(owner: playbackOwner) { [weak self] in self?.stopAll() }
        state = .preparingSpeech
        let generation = UUID()
        dictationGeneration = generation
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let microphoneGranted = await permissionProvider.requestMicrophonePermission()
            guard !Task.isCancelled else { return }
            guard microphoneGranted else {
                operationTask = nil
                state = .idle
                finishAudioSession()
                failureDidOccur?(.microphonePermissionDenied)
                return
            }
            let speechGranted = await permissionProvider.requestSpeechPermission()
            guard !Task.isCancelled else { return }
            guard speechGranted else {
                operationTask = nil
                state = .idle
                finishAudioSession()
                failureDidOccur?(.speechPermissionDenied)
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await configureCaptureSession()
                try Task.checkCancellation()
                guard dictationGeneration == generation else { return }
                try await speechTranscriber.start(
                    locale: SpeechConfiguration
                        .recognitionLocale(for: locale),
                    result: { [weak self] text, isFinal in
                        guard let self,
                              self.dictationGeneration == generation else {
                            return
                        }
                        self.state = .dictating(text: text)
                        if isFinal {
                            self.operationTask = nil
                            self.dictationGeneration = nil
                            self.speechTranscriber.stop()
                            self.state = .idle
                            self.finishAudioSession()
                        }
                    },
                    failure: { [weak self] in
                        guard let self,
                              self.dictationGeneration == generation else {
                            return
                        }
                        self.dictationGeneration = nil
                        self.operationTask = nil
                        self.speechTranscriber.stop()
                        self.state = .idle
                        self.finishAudioSession()
                        self.failureDidOccur?(.speechFailed)
                    }
                )
                guard !Task.isCancelled else {
                    speechTranscriber.stop()
                    return
                }
                if state == .preparingSpeech {
                    state = .dictating(text: "")
                }
                operationTask = nil
            } catch {
                guard dictationGeneration == generation else { return }
                operationTask = nil
                dictationGeneration = nil
                speechTranscriber.stop()
                state = .idle
                finishAudioSession()
                failureDidOccur?(.speechUnavailable)
            }
        }
    }

    /// 停止语音转写，并在编辑器中保留最新文本。
    func stopDictation() {
        let isActive: Bool
        if case .dictating = state {
            isActive = true
        } else {
            isActive = state == .preparingSpeech
        }
        guard isActive else { return }
        operationTask?.cancel()
        operationTask = nil
        dictationGeneration = nil
        speechTranscriber.stop()
        state = .idle
        finishAudioSession()
    }
}
