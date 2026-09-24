import AVFAudio
import Foundation

/// 配置并激活页面音频会话的对象；激活完成后才能启动媒体设备。
@MainActor
protocol AudioSessionControlling: AnyObject {
    /// 用于限定音频会话通知范围的对象。
    var notificationObject: AnyObject { get }
    /// 激活会话以捕获麦克风输入。
    func activateCapture() async throws
    /// 激活会话以播放音频消息。
    func activatePlayback() async throws
    /// 激活会话以播放附件预览中的音视频。
    func activatePreviewPlayback() async throws
    /// 按调用顺序提交停用请求；立即返回，不阻塞页面退出和所有权转移。
    func deactivate()
}

/// 聊天页面使用的真实音频会话控制器。
@MainActor
final class SystemAudioSessionController: AudioSessionControlling {
    /// 由此对象配置和激活的系统音频会话。
    private let session: AVAudioSession
    /// 所有真实控制器共用顺序队列，防止旧停用操作晚于新激活操作完成。
    private let operations: AudioSessionOperationQueue
    /// 用于限定音频生命周期通知来源的系统会话对象。
    var notificationObject: AnyObject { session }

    /// 包装指定会话；默认与其他音视频控制器共用应用会话和操作队列。
    init(session: AVAudioSession = .sharedInstance(),
         operations: AudioSessionOperationQueue? = nil) {
        self.session = session
        self.operations = operations ?? .shared
    }

    /// 使用支持扬声器和蓝牙 HFP 的语音录放模式激活采集会话。
    func activateCapture() async throws {
        try await activatePlayback()
    }

    /// 在后台配置语音录放模式，并等待系统确认激活。
    func activatePlayback() async throws {
        try await activate(category: .playAndRecord, mode: .spokenAudio,
                           options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    /// 在后台配置影片播放模式，并等待系统确认激活。
    func activatePreviewPlayback() async throws {
        try await activate(category: .playback, mode: .moviePlayback, options: [])
    }

    /// 同步入队异步停用请求，确保下一位所有者的激活一定排在其后。
    func deactivate() {
        operations.enqueue { [session] in
            // Xcode 27 / Swift 6.4 才提供这些异步 API；运行时检查无法屏蔽旧 SDK 缺失的符号。
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                guard try await session.deactivate(options: .notifyOthersOnDeactivation) else {
                    throw CocoaError(.featureUnsupported)
                }
            } else {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            #else
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    /// 配置和激活作为一项完整操作串行执行；同步系统 API 始终在后台调用。
    private func activate(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                          options: AVAudioSession.CategoryOptions) async throws {
        try Task.checkCancellation()
        let task = operations.enqueue { [session] in
            try session.setCategory(category, mode: mode, options: options)
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                guard try await session.activate() else { throw CocoaError(.featureUnsupported) }
            } else {
                try session.setActive(true)
            }
            #else
            try session.setActive(true)
            #endif
        }
        // 已入队的系统操作必须收尾；调用方停止时会立即在队列后方安排停用。
        try await task.value
        try Task.checkCancellation()
    }
}
