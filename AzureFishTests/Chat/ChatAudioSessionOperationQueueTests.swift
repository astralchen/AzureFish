import Foundation
import XCTest
@testable import AzureFish

/// 验证跨播放器的会话操作顺序及主线程响应能力。
@MainActor
final class ChatAudioSessionOperationQueueTests: XCTestCase {
    /// 激活挂起期间，MainActor 仍可提交停止和下一次激活；失败不能阻塞队列。
    func testSuspendedActivationKeepsMainActorResponsiveAndSerializesHandoff() async throws {
        guard #available(iOS 26.0, *) else { return }
        let queue = AudioSessionOperationQueue()
        let probe = AudioSessionQueueProbe()
        let started = expectation(description: "activation started off main thread")
        let first = queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            await probe.hold(started: started)
        }
        await fulfillment(of: [started], timeout: 3)
        // 若激活阻塞了 MainActor，这些提交和 release 都无法执行。
        let stop = queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            await probe.append("deactivate")
            throw CocoaError(.featureUnsupported)
        }
        let next = queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            await probe.append("next activate")
        }
        let before = await probe.events
        XCTAssertEqual(before, ["activate started"])
        await probe.release()
        try await first.value
        do { try await stop.value; XCTFail("预期停用错误") } catch {}
        try await next.value
        let after = await probe.events
        XCTAssertEqual(after, ["activate started", "activate finished", "deactivate", "next activate"])
    }
}

/// 在测试中挂起操作并收集跨线程事件，不使用阻塞等待。
private actor AudioSessionQueueProbe {
    /// 已发生的事件顺序。
    var events: [String] = []
    /// 挂起的首项激活操作。
    private var continuation: CheckedContinuation<Void, Never>?
    /// 通知激活开始，并等待测试释放。
    func hold(started: XCTestExpectation) async {
        events.append("activate started")
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
        events.append("activate finished")
    }
    /// 记录后续操作。
    func append(_ event: String) { events.append(event) }
    /// 允许首项操作结束。
    func release() { continuation?.resume(); continuation = nil }
}
