import AzureFishAPI
import UIKit

/// 视图内的图片绑定；相同资源重复配置时保留解码图片和未完成任务。
/// 身份包含账号、运行时及加密媒体存储，复用或资源替换时取消旧任务。
@MainActor
final class MomentsImageBinding {
    private struct Identity: Equatable {
        let runtime: ObjectIdentifier
        let account: String
        let storage: ObjectIdentifier?
        let target: String
        let cover: Bool
        let asset: ChatAsset?
    }
    private var identity: Identity?
    private var task: Task<Void, Never>?
    private var loaded = false
    private var generation = UUID()
    private weak var observedRuntime: MomentsRuntime?
    private var observation: UUID?

    /// 将缩略图绑定到按钮；身份改变时取消旧请求，重复配置同一身份时复用加载状态。
    func configure(_ button: UIButton, runtime: MomentsRuntime, asset: ChatAsset?, target: String, cover: Bool = false) {
        let next = Identity(runtime: ObjectIdentifier(runtime), account: runtime.userID,
            storage: runtime.media.map { ObjectIdentifier($0) }, target: target, cover: cover, asset: asset)
        if identity != next {
            if let observation { observedRuntime?.remove(observation) }
            task?.cancel(); task = nil; generation = UUID(); loaded = false; identity = next
            observedRuntime = runtime
            observation = runtime.observe { [weak self, weak runtime, weak button] in
                guard let self, let runtime, identity == next, loaded || task != nil else { return }
                let referenced = asset.map { runtime.referencesImage($0, target: target, cover: cover) } ?? false
                guard !referenced else { return }
                // 失权或退出时连复用池中的解码图片也清除，不依赖下一次 Cell 配置。
                task?.cancel(); task = nil; self.generation = UUID(); loaded = false; identity = nil
                button?.setImage(nil, for: .normal)
            }
            let cached = asset.flatMap { runtime.cachedThumbnail($0, target: target, cover: cover) }
            loaded = cached != nil
            button.contentHorizontalAlignment = cover && cached == nil ? .center : .fill
            button.contentVerticalAlignment = cover && cached == nil ? .center : .fill
            // 有资源时保持图片区域，不插入默认图；加密磁盘缓存也可能需要异步解密。
            button.setImage(cached ?? (asset == nil ? UIImage(systemName: "mountain.2") : nil), for: .normal)
        }
        guard !loaded, task == nil, let asset else { return }
        let generation = generation
        task = Task { [weak self, weak button] in
            defer { if self?.generation == generation { self?.task = nil } }
            do {
                let bytes = try await runtime.work { try await runtime.image(asset, target: target, cover: cover) }
                try Task.checkCancellation()
                guard self?.generation == generation, let image = UIImage(data: bytes) else { return }
                self?.loaded = true
                runtime.cacheThumbnail(image, asset: asset, target: target, cover: cover)
                button?.contentHorizontalAlignment = .fill; button?.contentVerticalAlignment = .fill
                button?.setImage(image, for: .normal)
            } catch {}
        }
    }
    isolated deinit {
        task?.cancel()
        if let observation { observedRuntime?.remove(observation) }
    }
}
