import Foundation

/// 主进程创建的受限明文任务；仅通过私有工作目录传递，不进入网络协议。
public struct WorkerJob: Codable, Sendable {
    public let kind: String
    public let original: String
    public let pairedVideo: String?
    public let outputDirectory: String
    public init(kind: String, original: String, pairedVideo: String?, outputDirectory: String) {
        self.kind = kind; self.original = original; self.pairedVideo = pairedVideo; self.outputDirectory = outputDirectory
    }
}
/// 工作进程返回的有限元数据；主进程仍校验输出名称、尺寸和字节上限。
public struct WorkerResult: Codable, Sendable {
    public var failure = ""
    public var mime = ""
    public var pairedMime = ""
    public var width = 0
    public var height = 0
    public var durationMS: Int64 = 0
    public var animated = false
    public var waveform: [Float] = []
    public var preview: String? = nil
    public init() {}
}
