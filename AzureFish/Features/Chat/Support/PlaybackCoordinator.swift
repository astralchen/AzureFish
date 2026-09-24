import Foundation

/// 页面内音频和视频共用的播放所有权。先同步停止旧对象，再交给新对象。
@MainActor
final class PlaybackCoordinator {
    /// 当前持有页面播放所有权的令牌；没有所有者时为 `nil`。
    private var owner: UUID?
    /// 同步停止当前所有者的闭包；转移或释放所有权后解除持有。
    private var stopOwner: (() -> Void)?

    /// 同步停止旧所有者，再将播放所有权交给指定令牌。
    ///
    /// - Parameters:
    ///   - newOwner: 新播放对象的稳定令牌；与当前令牌相同则直接返回。
    ///   - stop: 所有权被其他对象接管时调用的同步停止操作。
    func acquire(owner newOwner: UUID, stop: @escaping () -> Void) {
        guard owner != newOwner else { return }
        let stopPrevious = stopOwner
        // 旧对象的停止回调可以同步调用 release；先解除旧身份，再执行其清理。
        owner = nil
        stopOwner = nil
        stopPrevious?()
        owner = newOwner
        stopOwner = stop
    }

    /// 仅在令牌仍匹配当前所有者时释放所有权。
    ///
    /// 旧播放器的迟到清理不会释放较新的播放对象，也不会主动调用停止闭包。
    func release(owner previousOwner: UUID) {
        guard owner == previousOwner else { return }
        owner = nil
        stopOwner = nil
    }
}
