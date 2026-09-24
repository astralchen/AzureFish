import UIKit

/// 聊天和模态预览通过响应者链向动态创建的 TextKit、列表子视图提供同一页面服务。
@MainActor
protocol MediaImageLoadingOwner: AnyObject {
    /// 页面拥有的图片加载器，不能是进程级单例。
    var mediaImageLoader: MediaImageLoader { get }
}

/// 只加载缩略图的显示视图，按实际布局请求解码并在离屏时释放消费者和图片。
final class MediaImageView: UIImageView {
    /// 异步图像回填后使外层裁剪和阴影按实际内容重新布局。
    override var image: UIImage? {
        didSet { if oldValue !== image { superview?.setNeedsLayout() } }
    }

    /// 文件缩略图缺失或读取失败时使用的廉价系统图标。
    private var placeholderImage: UIImage?
    /// 当前缩略图文件；不允许隐式回退到原件。
    private var thumbnailURL: URL?
    /// 当前请求的显示尺寸和文件身份。
    private var binding: MediaImageLoader.Key?
    /// 当前消费者句柄。
    private var request: MediaImageLoader.Request?
    /// 当前页面服务的弱引用。
    private weak var loader: MediaImageLoader?
    /// 无页面宿主的独立组件预览使用本地服务。
    private var standaloneLoader: MediaImageLoader?
    /// 当前缩略图操作的有效期，拒绝复用后的迟到结果。
    private let thumbnailScope = OperationScope()
    /// 默认关闭；草稿卡片可在同一文件首次显示时启用短淡入。
    var thumbnailFadeDuration: TimeInterval = 0
    private var hasDisplayedThumbnail = false
    /// 由滚动容器传入的实际可见性。
    var isContentActive = true { didSet { if oldValue != isContentActive { updateThumbnail() } } }

    /// 系统菜单使用原视图快照期间，只保留已显示的图片，不启动额外读取。
    private var displayedContentRetainCount = 0

    /// 保留子树中已显示的缩略图，返回可重复调用的释放闭包；不读取原件。
    ///
    /// 保留期间只阻止离屏清理当前图片；Cell 改绑其他文件时仍应清除旧内容。
    ///
    /// - Parameter view: 包含当前消息媒体内容的源视图，遍历时包含视图自身。
    /// - Returns: 在主 actor 上调用的释放闭包；第一次调用减少保留计数并恢复可见性驱动的清理，重复调用无效。
    static func retainDisplayedContent(in view: UIView) -> () -> Void {
        var images: [MediaImageView] = []
        /// 递归登记子树中的媒体图片，每个视图为本次保留增加一次引用计数。
        func visit(_ view: UIView) {
            if let image = view as? MediaImageView {
                image.displayedContentRetainCount += 1
                images.append(image)
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        // 关闭、失效与销毁可能都请求释放，同一份保留只能减少一次计数。
        var released = false
        return {
            guard !released else { return }
            released = true
            for image in images {
                image.displayedContentRetainCount -= 1
                image.updateThumbnail()
            }
        }
    }

    /// 配置缩略图；同一文件保留已解码图片和在途请求。
    func setThumbnail(_ url: URL?, placeholder: UIImage? = nil) {
        placeholderImage = placeholder
        guard url != thumbnailURL else {
            if url == nil || image == nil || image?.isSymbolImage == true { image = placeholder }
            return
        }
        cancelThumbnail()
        thumbnailURL = url
        hasDisplayedThumbnail = false
        layer.removeAnimation(forKey: "thumbnailFade")
        image = placeholder
        setNeedsLayout()
    }

    /// 实际尺寸稳定后按目标像素解码。
    override func layoutSubviews() {
        super.layoutSubviews()
        updateThumbnail()
    }

    /// 离开窗口即释放图片，重新进入时恢复当前请求。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateThumbnail()
    }

    /// 获取页面注入服务；独立组件只在真实显示时创建自己的服务。
    private func resolveLoader() -> MediaImageLoader {
        var responder: UIResponder? = self
        while let current = responder {
            if let owner = current as? MediaImageLoadingOwner { return owner.mediaImageLoader }
            responder = current.next
        }
        if let standaloneLoader { return standaloneLoader }
        let value = MediaImageLoader()
        standaloneLoader = value
        return value
    }

    /// 复用和离屏时取消当前消费者，失效回调不得回填。
    private func cancelThumbnail() {
        thumbnailScope.invalidate()
        loader?.cancel(request)
        request = nil
        binding = nil
    }

    /// 可见时才读取文件，尺寸及模式不变时不重复加载。
    func updateThumbnail() {
        guard window != nil, isContentActive, !isHidden, let thumbnailURL else {
            cancelThumbnail()
            layer.removeAnimation(forKey: "thumbnailFade")
            if self.thumbnailURL != nil, displayedContentRetainCount == 0 { image = nil }
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let service = resolveLoader()
        let scale = max(1, traitCollection.displayScale)
        let mode: MediaImageLoader.Mode = contentMode == .scaleAspectFit ? .fit : .fill
        let key = MediaImageLoader.Key(url: thumbnailURL, width: Int(ceil(bounds.width * scale)),
            height: Int(ceil(bounds.height * scale)), mode: mode)
        guard binding != key || loader !== service else { return }
        cancelThumbnail()
        loader = service
        binding = key
        let operation = thumbnailScope.begin()
        if image == nil { image = placeholderImage }
        request = service.load(url: thumbnailURL, size: CGSize(width: key.width, height: key.height), mode: mode) { [weak self] image in
            guard let self, operation.isCurrent else { return }
            request = nil
            let shouldFade = image != nil && !hasDisplayedThumbnail && thumbnailFadeDuration > 0 && UIView.areAnimationsEnabled
            if image != nil { hasDisplayedThumbnail = true }
            self.image = image ?? placeholderImage
            if shouldFade {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = thumbnailFadeDuration
                layer.add(fade, forKey: "thumbnailFade")
            }
        }
    }

    /// 列表宿主按显示生命周期递归切换其子树的缩略图消费者。
    static func setContentActive(_ active: Bool, in view: UIView) {
        if let imageView = view as? MediaImageView { imageView.isContentActive = active }
        view.subviews.forEach { setContentActive(active, in: $0) }
    }

    /// 未进入复用池的视图释放时也取消其消费者。
    isolated deinit { loader?.cancel(request) }
}
