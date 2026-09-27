import Foundation
import Darwin
import MediaWorkerSupport

@main
struct MediaWorkerMain {
    static func main() async {
        umask(0o077)
        guard CommandLine.arguments.count == 2 else { return }
        let jobURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var result = WorkerResult()
        do {
            let job = try JSONDecoder().decode(WorkerJob.self, from: Data(contentsOf: jobURL))
            result = try await NativeMediaProcessor.process(job)
        } catch { result.failure = "INVALID_MEDIA" }
        // 底层解码异常和文件名均不写入 stdout/stderr。
        if let bytes = try? JSONEncoder().encode(result) {
            try? bytes.write(to: jobURL.deletingLastPathComponent().appendingPathComponent("result.json"), options: .atomic)
        }
    }
}
