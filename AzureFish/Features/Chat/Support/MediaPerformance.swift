import os

/// Instruments 中区分文件复制、媒体处理与图片解码的轻量 signpost。
nonisolated enum MediaPerformance {
    /// 不记录文件路径或照片内容，仅记录各阶段耗时。
    static let signposter = OSSignposter(subsystem: "com.quicklayout.demo", category: "MediaPipeline")
}
