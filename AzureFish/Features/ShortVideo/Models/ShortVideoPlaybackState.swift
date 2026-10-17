import Foundation

/// 播放资格与异步加载身份；页面、前台及遮挡状态全部允许时才能自动播放。
struct ShortVideoPlaybackState {
    private(set) var generation = UUID()
    var visible = false
    var foreground = true
    var obscured = false
    var paused = false
    var scrolling = false
    var canPlay: Bool { visible && foreground && !obscured && !paused && !scrolling }
    mutating func invalidate() { generation = UUID() }
    func accepts(_ token: UUID) -> Bool { token == generation && visible && foreground && !obscured }
}
