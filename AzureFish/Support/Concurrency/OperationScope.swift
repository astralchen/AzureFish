import Foundation

/// 管理主 Actor 上一个可被替换或停止的操作的有效期。
///
/// 可用于异步函数、系统回调及多个任务共用的会话。此对象只管理有效性，
/// 不取消底层任务或释放业务资源；调用方应在开始新操作或停止时完成相应清理。
@MainActor
final class OperationScope {
    /// 当前有效操作的身份；没有活动操作时为 `nil`。
    private var currentID: UUID?

    /// 标识一次操作，不延长所属 Scope 或业务对象的生命周期。
    @MainActor
    struct Token {
        /// 创建此令牌的 Scope；Scope 释放后令牌自动失效。
        private weak var scope: OperationScope?
        /// 本次操作的稳定身份。
        private let id: UUID

        /// 为指定 Scope 的操作创建令牌，仅由 `begin()` 调用。
        fileprivate init(scope: OperationScope, id: UUID) {
            self.scope = scope
            self.id = id
        }

        /// 本次操作是否仍有效；与当前执行任务的取消状态无关。
        ///
        /// 普通回调过滤和资源归属检查应使用此属性。任务被取消后仍可能需要
        /// 清理其拥有的资源，因此这里不会检查 `Task.isCancelled`。
        var isCurrent: Bool { scope?.currentID == id }

        /// 当前任务已取消，或操作被替换、停止、释放时，抛出 `CancellationError`。
        ///
        /// 在关键 `await` 返回后、修改状态或启动硬件之前调用；检查不会撤销
        /// 已发生的副作用，也不会自动清理刚刚取得的资源。
        func checkCancellation() throws {
            try Task.checkCancellation()
            guard isCurrent else { throw CancellationError() }
        }
    }

    /// 创建初始没有有效操作的 Scope。
    init() {}

    /// 开始新操作并使之前的所有令牌失效；不取消它们关联的底层工作。
    func begin() -> Token {
        let id = UUID()
        currentID = id
        return Token(scope: self, id: id)
    }

    /// 使当前操作失效；重复调用没有额外作用。
    func invalidate() {
        currentID = nil
    }
}
