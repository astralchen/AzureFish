//
//  AudioController.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 为单个聊天页面协调音频录制、播放、语音转写和音频会话所有权。
///
/// 此控制器串行执行音频操作，确保录音与语音转写不会同时使用麦克风。页面附件
/// 文件由独立的 ``AttachmentStoring`` 管理，图片和视频功能不应加入
/// 此控制器。
@available(iOS 26.0, *)
@MainActor
final class AudioController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    /// 输入栏录音、预览或听写状态变化的回调类型。
    typealias StateHandler = (ComposerState) -> Void
    /// 时间线音频播放状态变化的回调类型。
    typealias PlaybackHandler = (PlaybackState) -> Void
    /// 向界面报告媒体操作失败的回调类型。
    typealias FailureHandler = (MediaFailure) -> Void

    /// 区分草稿预览与已发送消息的播放目标。
    enum PlaybackTarget: Equatable {
        /// 播放指定稳定身份的音频草稿。
        case preview(UUID)
        /// 播放由消息身份与附件身份共同确定的时间线音频。
        case message(id: Int, attachmentID: UUID)
    }

    /// 输入栏媒体状态发生变化时调用的闭包。
    var stateDidChange: StateHandler?

    /// 时间线音频播放状态发生变化时调用的闭包。
    var playbackDidChange: PlaybackHandler?

    /// 当前操作需要向用户反馈时调用的闭包。
    var failureDidOccur: FailureHandler?

    /// 输入栏当前的媒体状态；值发生变化时同步通知观察者。
    var state: ComposerState = .idle {
        didSet {
            guard state != oldValue else { return }
            stateDidChange?(state)
        }
    }

    /// 时间线当前的音频播放状态；值发生变化时同步通知观察者。
    var playbackState: PlaybackState = .idle {
        didSet {
            guard playbackState != oldValue else { return }
            playbackDidChange?(playbackState)
        }
    }

    /// 负责激活和释放音频会话的协作者。
    let audioSession: AudioSessionControlling
    /// 指示当前控制器是否持有已激活音频会话的布尔值。
    var ownsAudioSession = false
    /// 音频会话占用的代次；释放或重新申请后旧激活结果立即失效。
    var audioSessionGeneration = 0
    /// 等待音频播放会话激活的任务；暂停或切换目标时取消。
    let playbackTask = LatestTask()
    /// 与页面视频预览共享的播放互斥协调器。
    let playbackCoordinator = PlaybackCoordinator()
    /// 当前音频控制器获取和释放播放所有权时使用的稳定令牌。
    let playbackOwner = UUID()
    /// 负责草稿及已提交音频文件生命周期的页面存储。
    let attachmentStore: any AttachmentStoring
    /// 检查和删除录音、合成音频文件的文件管理器。
    let fileManager: FileManager
    /// 将实时麦克风输入转换为文本的服务。
    let speechTranscriber: SpeechTranscribing
    /// 请求麦克风和语音识别权限的协作者。
    let permissionProvider: MediaPermissionProviding

    /// 当前录音器；没有活动录音时为 `nil`。
    var recorder: AVAudioRecorder?
    /// 定期更新录音时长和音量的主运行循环计时器。
    var recordingTimer: Timer?
    /// 本次录音按时间顺序收集的归一化音量采样。
    var recordingSamples: [Float] = []
    /// 当前录音正在写入的文件 URL。
    var recordingURL: URL?
    /// 当前音频播放器；停止播放并清理后为 `nil`。
    var player: AVAudioPlayer?
    /// 当前播放器对应的草稿或消息身份。
    var playbackTarget: PlaybackTarget?
    /// 定期发布音频播放进度的主运行循环计时器。
    var playbackTimer: Timer?
    /// 生成模拟音频回复的系统语音合成器。
    var replyAudioSynthesizer: AVSpeechSynthesizer?
    /// 正在进行的回复合成上下文；负责输出文件与结果延续。
    var replyAudioSynthesisContext:
        ReplyAudioSynthesisContext?
    /// 当前权限请求或语音启动操作的可取消任务。
    var operationTask: Task<Void, Never>?
    /// 当前听写会话的令牌，用于过滤停止后到达的识别回调。
    var dictationGeneration: UUID?
    /// 系统音频会话中断通知的观察令牌。
    var interruptionObserver: NSObjectProtocol?
    /// 音频输出路由变化通知的观察令牌。
    var routeObserver: NSObjectProtocol?
    /// 应用进入后台通知的观察令牌。
    var backgroundObserver: NSObjectProtocol?

    /// 创建使用共享音频会话和系统语音识别器的媒体控制器。
    convenience override init() {
        self.init(
            audioSession: SystemAudioSessionController(),
            fileManager: .default,
            speechTranscriber: SpeechRecognitionService(),
            permissionProvider: SystemPermissionProvider(),
            attachmentStore: nil
        )
    }

    /// 创建与其他页面媒体协调器共享附件目录的真实音频控制器。
    convenience init(attachmentStore: any AttachmentStoring) {
        self.init(
            audioSession: SystemAudioSessionController(),
            fileManager: .default,
            speechTranscriber: SpeechRecognitionService(),
            permissionProvider: SystemPermissionProvider(),
            attachmentStore: attachmentStore
        )
    }

    /// 使用可注入的系统协作者创建媒体控制器。
    ///
    /// - Parameters:
    ///   - audioSession: 用于捕获和播放会话的控制器。
    ///   - fileManager: 用于创建和移除录音的文件管理器。
    ///   - speechTranscriber: 提供实时语音结果的对象。
    ///   - permissionProvider: 请求麦克风和 Speech 权限的对象。
    ///   - attachmentStore: 页面附件存储。传入 `nil` 时创建独立临时目录。
    init(
        audioSession: AudioSessionControlling,
        fileManager: FileManager,
        speechTranscriber: SpeechTranscribing,
        permissionProvider: MediaPermissionProviding,
        attachmentStore: (any AttachmentStoring)? = nil
    ) {
        self.audioSession = audioSession
        self.fileManager = fileManager
        self.speechTranscriber = speechTranscriber
        self.permissionProvider = permissionProvider
        self.attachmentStore = attachmentStore
            ?? PageAttachmentStore(fileManager: fileManager)
        super.init()
        observeAudioLifecycle()
    }

    /// 取消异步操作、停止音频设备与计时器，并释放合成资源和通知观察者。
    isolated deinit {
        operationTask?.cancel()
        playbackTask.cancel()
        replyAudioSynthesizer?.stopSpeaking(at: .immediate)
        if let context = replyAudioSynthesisContext {
            context.audioFile = nil
            try? fileManager.removeItem(at: context.fileURL)
            context.continuation?.resume(throwing: CancellationError())
            context.continuation = nil
        }
        recordingTimer?.invalidate()
        playbackTimer?.invalidate()
        recorder?.stop()
        player?.stop()
        if ownsAudioSession { audioSession.deactivate() }
        playbackCoordinator.release(owner: playbackOwner)
        let speechTranscriber = speechTranscriber
        Task { @MainActor in
            speechTranscriber.stop()
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    /// 停止所有活动的媒体操作并释放音频会话。
///
    /// 有效的活动录音会保留为预览。播放和语音转写不会自动恢复。
    func stopAll() {
        operationTask?.cancel()
        operationTask = nil
        cancelReplyAudioSynthesis()
        dictationGeneration = nil
        speechTranscriber.stop()
        if recorder != nil {
            finishRecording(keepValidRecording: true)
        }
        stopPlayback()
        if case .dictating = state {
            state = .idle
        } else if state == .preparingSpeech {
            state = .idle
        }
        finishAudioSession()
    }

    /// 没有有效采样时使用的 36 槽位最低振幅波形。
    static let placeholderWaveform: [Float] = Array(
        repeating: 0.08,
        count: 36
    )
}
