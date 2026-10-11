import AzureFishAPI
import UIKit

/// 当前及相邻页按需加载；已完成图片优先命中缓存，跨页复用进行中的请求。
/// 停止时取消所有请求并拒绝迟到结果；账号缓存由运行时负责失权清理。
@MainActor
final class MomentsPhotoLoader {
    enum State {
        case loading
        case image(UIImage)
        case preview(UIImage, failure: String?)
        case failed(String)
    }
    private let assets: [ChatAsset]
    private let cache: MomentsPhotoCache
    private let target: String
    private let placeholder: @MainActor (ChatAsset) -> UIImage?
    private var failures: [Int: String] = [:]
    private let fetch: @MainActor (ChatAsset) async throws -> Data
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var generations: [Int: UUID] = [:]
    private(set) var states: [Int: State] = [:]
    private(set) var retained: Set<Int> = []
    var didChange: (() -> Void)?
    init(assets: [ChatAsset], target: String = "", cache: MomentsPhotoCache = MomentsPhotoCache(),
         placeholder: @escaping @MainActor (ChatAsset) -> UIImage? = { _ in nil },
         fetch: @escaping @MainActor (ChatAsset) async throws -> Data) {
        self.assets = assets; self.target = target; self.cache = cache; self.placeholder = placeholder; self.fetch = fetch
    }
    /// 保留当前页及相邻页的展示状态；窗口外未完成请求继续执行，便于快速往返复用。
    func updateWindow(around index: Int) {
        let next = Set((index - 1...index + 1).filter { assets.indices.contains($0) })
        guard next != retained else { return }
        for index in retained.subtracting(next) {
            states[index] = nil
        }
        retained = next
        for index in next where states[index] == nil { start(index) }
        didChange?()
    }
    /// 仅重试当前保留窗口中已经失败的页面。
    func retry(_ index: Int) {
        guard retained.contains(index), failures.removeValue(forKey: index) != nil else { return }
        start(index); didChange?()
    }
    /// 取消请求并清除本加载器状态；共享缓存由运行时另行管理。
    func stop() {
        tasks.values.forEach { $0.cancel() }; tasks = [:]; generations = [:]; states = [:]; retained = []; failures = [:]
    }
    private func start(_ index: Int) {
        let asset = assets[index]
        if let image = cache.image(for: asset, target: target) { states[index] = .image(image); return }
        let preview = placeholder(asset)
        if let failure = failures[index] {
            states[index] = preview.map { .preview($0, failure: failure) } ?? .failed(failure)
            return
        }
        states[index] = preview.map { .preview($0, failure: nil) } ?? .loading
        guard tasks[index] == nil else { return }
        let generation = UUID(), fetch = fetch
        generations[index] = generation
        tasks[index] = Task { [weak self] in
            let result: State
            do {
                let bytes = try await fetch(asset)
                try Task.checkCancellation()
                guard let image = UIImage(data: bytes) else { throw APIClientError.invalidRequest }
                result = .image(image)
            } catch is CancellationError { return }
            catch { result = .failed(momentsErrorKey(error)) }
            // 取消并不保证底层回调不再到达，以请求代次拒绝停止或重启后的迟到结果。
            guard let self, generations[index] == generation else { return }
            tasks[index] = nil; generations[index] = nil
            switch result {
            case .image(let image): cache.insert(image, asset: asset, target: target)
            case .failed(let key): failures[index] = key
            default: break
            }
            guard retained.contains(index) else { return }
            if case .failed(let key) = result, let preview { states[index] = .preview(preview, failure: key) }
            else { states[index] = result }
            didChange?()
        }
    }

    isolated deinit { tasks.values.forEach { $0.cancel() } }
}
