import AVFoundation
import ImageIO
import PDFKit
import UIKit
import os
import QuickLayout
import QuickLayoutKit

/// 一个可复用预览页，负责只读内容、缩放和可取消的原图加载。
final class AttachmentPreviewPage: QuickLayoutCollectionViewCell, UIScrollViewDelegate {
    /// 分页固定为物理 LTR；文字方向由预览控制器设置，不从分页列表覆盖。
    override func synchronizeLayoutDirectionFromCollectionViewIfNeeded() -> Bool { false }

    let imageScrollView = UIScrollView()
    let imageView = UIImageView()
    let playerLayer = AVPlayerLayer()
    private(set) var livePhotoPlayer: AttachmentLivePhotoPlayer?
    private var livePhotoMode: LivePhotoPlaybackMode = .live
    var photoGeometryDidChange: (() -> Void)?
    private lazy var livePress = UILongPressGestureRecognizer(target: self, action: #selector(livePhotoPressed(_:)))
    /// 未缩放图片的位置供固定控制层定位，避免手势缩放改变标识位置。
    var fittedPhotoRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: imageSize, insideRect: bounds)
    }
    /// 布局引擎放置视频画布；AVPlayerLayer 只同步其本地 bounds。
    private let videoSurface = UIView()

    /// 常规内容由 QuickLayout 放置，缩放图像保留 UIScrollView 的坐标语义。
    override var body: Layout {
        ZStack {
            imageScrollView.resizable()
            videoSurface.resizable()
            if let pdfView { pdfView.resizable().padding(.top, documentTop).padding(.bottom, documentBottom) }
            if let textView { textView.resizable().padding(.top, documentTop).padding(.bottom, documentBottom) }
            messageLabel.resizable().padding(.horizontal, 28).padding(.vertical, 120)
            loading.resizable().frame(width: 44, height: 44)
        }
    }
    private var documentTop: CGFloat { max(documentTopInset, max(88, safeAreaInsets.top + 72)) }
    private var documentBottom: CGFloat { max(24, safeAreaInsets.bottom + 12) }
    private(set) var pdfView: PDFView?
    private(set) var textView: UITextView?
    private let messageLabel = UILabel()
    private let loading = UIActivityIndicatorView(style: .large)
    private var imageTask: Task<Void, Never>?
    /// 当前页使用的页面图片服务。
    private var mediaLoader: MediaImageLoader?
    /// 当前配置，离屏后再次显示时恢复缩略图请求。
    private var representedItem: AttachmentPreviewItem?
    /// 缩略图消费者句柄。
    private var thumbnailRequest: MediaImageLoader.Request?
    /// 最近请求的缩略图尺寸。
    private var thumbnailPixels = CGSize.zero
    /// 原图加载期间和翻页过程中显示的缩略图。
    private var previewThumbnail: UIImage?
    /// 完整原图任务，只有正式当前页能启动。
    private var originalTask: Task<Void, Never>?
    /// 原图回填代次。
    private var originalGeneration = UUID()
    /// 离屏后布局回调不得重新启动图片读取。
    private var imagesAreVisible = true
    /// 配置回填代次，防止同一项目复用后旧缩略图回填。
    private var configurationGeneration = UUID()
    /// 当前页是否拥有完整原图显示资格。
    private(set) var isOriginalActive = false
    /// 图像是否已经达到原始分辨率。
    private(set) var hasOriginalImage = false
    private var pdfObserver: NSObjectProtocol?
    private(set) var itemID: UUID?
    /// 视频转场只复制静态封面，不能对已绑定播放器的整页创建系统快照。
    private var isVideo = false
    private var imageSize = CGSize.zero
    private var previousSize = CGSize.zero
    /// 由控制层的实际高度决定文档起点，大字号下首行也必须完整可读。
    var documentTopInset: CGFloat = 0 {
        didSet { if documentTopInset != oldValue { setNeedsLayout() } }
    }
    /// 单击媒体背景时切换玻璃控件。
    var toggleControls: (() -> Void)?
    /// PDF 页码变化时刷新顶部状态。
    var pageDidChange: ((Int, Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fixedSize
        contentView.backgroundColor = .clear
        imageScrollView.minimumZoomScale = 1
        imageScrollView.maximumZoomScale = 4
        imageScrollView.delegate = self
        imageScrollView.contentInsetAdjustmentBehavior = .never
        imageScrollView.showsVerticalScrollIndicator = false
        imageScrollView.showsHorizontalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        imageScrollView.addSubview(imageView)
        playerLayer.videoGravity = .resizeAspect
        videoSurface.isUserInteractionEnabled = false
        videoSurface.layer.addSublayer(playerLayer)
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .white
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.accessibilityIdentifier = "imessage.preview.message"
        loading.color = .white
        loading.hidesWhenStopped = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageScrollView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        tap.require(toFail: doubleTap)
        imageScrollView.addGestureRecognizer(tap)
        livePress.minimumPressDuration = 0.3
        livePress.isEnabled = false
        imageScrollView.addGestureRecognizer(livePress)
        tap.require(toFail: livePress)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 展示指定项目并拒绝已复用页面的迟到加载结果。
    func configure(_ item: AttachmentPreviewItem, imageLoader: MediaImageLoader? = nil, isVisible: Bool = true, playbackCoordinator: PlaybackCoordinator? = nil) {
        reset()
        mediaLoader = imageLoader ?? mediaLoader ?? MediaImageLoader()
        representedItem = item
        imagesAreVisible = isVisible
        itemID = item.id
        isVideo = item.kind == .video
        if item.isLivePhoto, let playbackCoordinator {
            let player = AttachmentLivePhotoPlayer(coordinator: playbackCoordinator)
            player.didFail = { [weak self] in self?.showLivePhotoError() }
            livePhotoPlayer = player
            imageView.addSubview(player.view)
            imageView.addSubview(player.effect.view)
        }
        accessibilityIdentifier = "imessage.preview.page.\(item.id.uuidString)"
        switch item.kind {
        case .image, .video:
            imageScrollView.isHidden = false
            imageScrollView.maximumZoomScale = item.kind == .image ? 4 : 1
            loadThumbnailIfNeeded()
        case .pdf:
            loading.startAnimating()
            let id = item.id
            let task = Task.detached(priority: .userInitiated) { try? Data(contentsOf: item.url, options: .mappedIfSafe) }
            imageTask = Task { [weak self] in
                let data = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
                guard !Task.isCancelled, let self, itemID == id else { return }
                loading.stopAnimating()
                guard let data, let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { showError(); return }
                let pdf = PDFView()
                pdf.autoScales = true
                pdf.displayMode = .singlePageContinuous
                pdf.displayDirection = .vertical
                pdf.backgroundColor = .secondarySystemBackground
                pdf.document = document
                pdf.accessibilityIdentifier = "imessage.preview.pdf"
                pdfView = pdf
                pdfObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdf, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportPDFPage() }
                }
                setNeedsLayout()
                reportPDFPage()
            }
        case .text(let text):
            let view = UITextView()
            view.text = text
            view.isEditable = false
            view.isSelectable = true
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.textColor = .label
            view.backgroundColor = .systemBackground
            view.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
            view.accessibilityIdentifier = "imessage.preview.text"
            textView = view
        case .audio:
            messageLabel.text = "♫\n\n\(item.title)"
        case .quickLook, .unavailable:
            showError()
        }
        setNeedsLayout()
    }

    /// 当前内容允许向下关闭时为 true；放大和文本选择具有优先权。
    var permitsDismissal: Bool {
        if imageScrollView.zoomScale > 1.01 { return false }
        if let textView {
            return textView.selectedRange.length == 0 && textView.contentOffset.y <= -textView.adjustedContentInset.top + 1
        }
        if let pdfView {
            if pdfView.currentSelection != nil || pdfView.scaleFactor > pdfView.scaleFactorForSizeToFit + 0.01 { return false }
            guard let scroll = Self.firstScrollView(in: pdfView) else { return false }
            return scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
        }
        return true
    }

    /// 用于卡片展开匹配的内容矩形。
    var transitionRect: CGRect {
        if !imageScrollView.isHidden, imageSize.width > 0 { return imageView.convert(imageView.bounds, to: self) }
        return contentView.bounds
    }

    /// 视频的展开和收回使用封面，避免快照复制视频输出导致后续播放停帧。
    /// 没有封面时返回 nil，由宿主淡入淡出；其他内容保留原有快照行为。
    func transitionSnapshot(afterScreenUpdates: Bool) -> UIView? {
        if isVideo || representedItem?.isLivePhoto == true {
            guard let image = imageView.image else { return nil }
            let snapshot = UIImageView(image: image)
            snapshot.contentMode = .scaleAspectFill
            snapshot.clipsToBounds = true
            return snapshot
        }
        return resizableSnapshotView(from: transitionRect, afterScreenUpdates: afterScreenUpdates, withCapInsets: .zero)
    }

    /// 仅在播放器身份变化时接入或解除视频输出；同一实例不得被进度刷新重复绑定。
    /// 视频图层切换时保留静态封面，首帧准备后由播放器覆盖。
    func bind(player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    func showError() {
        loading.stopAnimating()
        messageLabel.text = Localization.text("imessage.preview.unavailable")
        messageLabel.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        loadThumbnailIfNeeded()
        if previousSize != bounds.size {
            previousSize = bounds.size
            imageScrollView.zoomScale = 1
            layoutImage()
        }
        livePhotoPlayer?.view.frame = imageView.bounds
        livePhotoPlayer?.effect.view.frame = imageView.bounds
        photoGeometryDidChange?()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = videoSurface.bounds
        CATransaction.commit()

    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        imageView.center = CGPoint(x: max(scrollView.contentSize.width, scrollView.bounds.width) / 2,
                                   y: max(scrollView.contentSize.height, scrollView.bounds.height) / 2)
    }
    @objc private func singleTapped() { toggleControls?() }
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard imageScrollView.maximumZoomScale > 1 else { toggleControls?(); return }
        if imageScrollView.zoomScale > 1 { imageScrollView.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled); return }
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        imageScrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    /// 图片升级时保持用户缩放和可见区域，避免原图就绪把视口跳回中央。
    private func apply(_ image: UIImage) {
        let zoom = imageScrollView.zoomScale
        let offset = imageScrollView.contentOffset
        imageScrollView.zoomScale = 1
        imageView.image = image
        imageSize = image.size
        layoutImage()
        imageScrollView.zoomScale = zoom
        imageScrollView.contentOffset = offset
    }

    /// 只有稳定当前页可以读取完整原图；取消不提前归还同步解码槽位。
    func setOriginalActive(_ active: Bool) {
        let active = active && imagesAreVisible && representedItem?.kind == .image
        guard active != isOriginalActive else { return }
        isOriginalActive = active
        updateLivePhotoEligibility()
        originalGeneration = UUID()
        originalTask?.cancel()
        originalTask = nil
        hasOriginalImage = false
        if let previewThumbnail { apply(previewThumbnail) } else { imageView.image = nil }
        guard active, let item = representedItem, let mediaLoader else { loading.stopAnimating(); return }
        loading.startAnimating()
        messageLabel.isHidden = true
        let token = originalGeneration
        let readyInterval = MediaPerformance.signposter.beginInterval("OriginalReady", id: MediaPerformance.signposter.makeSignpostID())
        originalTask = Task { [weak self] in
            defer { MediaPerformance.signposter.endInterval("OriginalReady", readyInterval) }
            do {
                let original = try await mediaLoader.originalContent(url: item.url)
                guard !Task.isCancelled, let self, originalGeneration == token, isOriginalActive else { return }
                let image = original.image
                hasOriginalImage = true
                loading.stopAnimating()
                apply(image)
                if original.isAnimatedGIF, !item.isLivePhoto { playGIF(url: item.url, generation: token) }
                #if MEDIA_BENCHMARK
                mediaLoader.benchmarkOriginalDisplayed?(item.url, CGSize(width: image.cgImage?.width ?? 0, height: image.cgImage?.height ?? 0))
                #endif
                originalTask = nil
            } catch {
                guard !Task.isCancelled, let self, originalGeneration == token, isOriginalActive else { return }
                originalTask = nil
                showError()
            }
        }
    }

    /// 系统按 GIF 原始帧时长自动播放；仅替换像素，不重置缩放或照片几何。
    /// 使用原图代次结束离页/复用后的回调，不额外持有整组解码帧。
    private func playGIF(url: URL, generation: UUID) {
        let status = CGAnimateImageAtURLWithBlock(url as CFURL,
            [kCGImageAnimationLoopCount: kCFNumberPositiveInfinity!] as CFDictionary) { [weak self] _, frame, stop in
                // ImageIO 明确保证逐帧回调运行在主队列。
                MainActor.assumeIsolated {
                    guard let self, self.originalGeneration == generation, self.isOriginalActive else {
                        stop.pointee = true
                        return
                    }
                    self.imageView.image = UIImage(cgImage: frame)
                }
            }
        if status != 0 { showError() }
    }

    func setLivePhotoMode(_ mode: LivePhotoPlaybackMode) {
        if livePhotoMode == mode {
            if mode.isContinuous { updateLivePhotoEligibility() }
            return
        }
        livePhotoMode = mode
        if mode != .off { messageLabel.isHidden = true }
        updateLivePhotoEligibility()
    }

    func stopLivePhotoPlayback() { livePhotoPlayer?.stop() }

    private func updateLivePhotoEligibility() {
        let active = isOriginalActive && livePhotoMode != .off && representedItem?.isLivePhoto == true
        livePress.isEnabled = active && livePhotoMode == .live
        imageScrollView.accessibilityCustomActions = livePress.isEnabled ? [UIAccessibilityCustomAction(
            name: Localization.text("imessage.preview.live.play"), actionHandler: { [weak self] _ in
                self?.livePhotoPlayer?.play()
                return self?.livePhotoPlayer?.isReady == true
            })] : nil
        guard active, let item = representedItem, let video = item.livePhotoVideoURL else {
            livePhotoPlayer?.unload()
            return
        }
        let scale = max(1, traitCollection.displayScale)
        let targetSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if livePhotoMode.isContinuous {
            livePhotoPlayer?.unload()
            livePhotoPlayer?.playEffect(video: video, mode: livePhotoMode, targetSize: targetSize)
        } else {
            livePhotoPlayer?.prepare(photo: item.url, video: video, placeholder: imageView.image, targetSize: targetSize)
        }
    }

    @objc private func livePhotoPressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: livePhotoPlayer?.play()
        case .ended, .cancelled, .failed: livePhotoPlayer?.stop()
        default: break
        }
    }

    private func showLivePhotoError() {
        messageLabel.text = Localization.text("imessage.preview.live.unavailable")
        messageLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: messageLabel.text)
    }

    /// 显示阶段只从 thumbnailURL 读取封面，永远不以原件作为缩略图回退。
    private func loadThumbnailIfNeeded() {
        guard imagesAreVisible, let item = representedItem, item.kind == .image || item.kind == .video,
              let url = item.thumbnailURL, let mediaLoader, bounds.width > 0, bounds.height > 0 else { return }
        let scale = max(1, traitCollection.displayScale)
        let pixels = CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        guard pixels != thumbnailPixels else { return }
        mediaLoader.cancel(thumbnailRequest)
        thumbnailPixels = pixels
        let token = configurationGeneration
        thumbnailRequest = mediaLoader.load(url: url, size: pixels, mode: .fit) { [weak self] image in
            guard let self, configurationGeneration == token, thumbnailPixels == pixels else { return }
            thumbnailRequest = nil
            previewThumbnail = image
            if !hasOriginalImage, let image { apply(image) }
        }
    }

    /// 离屏立即释放大图和缩略图消费者；再显示时无需重新配置项目。
    func suspendImages() {
        imagesAreVisible = false
        setOriginalActive(false)
        configurationGeneration = UUID()
        mediaLoader?.cancel(thumbnailRequest)
        thumbnailRequest = nil
        thumbnailPixels = .zero
        previewThumbnail = nil
        if representedItem?.kind == .image || representedItem?.kind == .video { imageView.image = nil }
    }

    /// 可复用页再次进入视口时恢复封面请求。
    func resumeImages() { imagesAreVisible = true; loadThumbnailIfNeeded() }
    private func layoutImage() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageView.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        imageScrollView.contentSize = bounds.size
        livePhotoPlayer?.view.frame = imageView.bounds
        livePhotoPlayer?.effect.view.frame = imageView.bounds
        photoGeometryDidChange?()
    }
    private func reportPDFPage() {
        guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else { return }
        pageDidChange?(document.index(for: page) + 1, document.pageCount)
    }
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }
    /// 取消页面加载并清除仅属于当前项目的观察者。
    func reset() {
        suspendImages()
        livePhotoPlayer?.unload()
        livePhotoPlayer?.view.removeFromSuperview()
        livePhotoPlayer?.effect.view.removeFromSuperview()
        livePhotoPlayer = nil
        livePhotoMode = .live
        livePress.isEnabled = false
        imageScrollView.accessibilityCustomActions = nil
        representedItem = nil
        imageTask?.cancel(); imageTask = nil
        if let pdfObserver { NotificationCenter.default.removeObserver(pdfObserver) }
        pdfObserver = nil
        itemID = nil
        isVideo = false
        playerLayer.player = nil
        pdfView?.removeFromSuperview(); pdfView = nil
        textView?.removeFromSuperview(); textView = nil
        imageScrollView.zoomScale = 1
        imageScrollView.isHidden = true
        imageView.image = nil
        imageSize = .zero
        messageLabel.text = nil
        loading.stopAnimating()
    }
    override func prepareForReuse() { super.prepareForReuse(); reset(); toggleControls = nil; pageDidChange = nil; photoGeometryDidChange = nil }
    isolated deinit { originalTask?.cancel(); mediaLoader?.cancel(thumbnailRequest); imageTask?.cancel(); if let pdfObserver { NotificationCenter.default.removeObserver(pdfObserver) } }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("附件内容 · 图片") {
    let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    page.backgroundColor = .black
    page.configure(ConversationPreviewData.attachmentPreviewItems[0])
    return page
}
#endif
