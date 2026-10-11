import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 封面裁剪以可见窗口为目标，缩放与拖动后导出不带位置元数据的 JPEG。
final class MomentsCoverCropController: LocalizedQuickLayoutHostingController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let imageView: UIImageView
    private let source: UIImage
    private let done: (Data) -> Void
    private var previousSize = CGSize.zero
    init(image: UIImage, done: @escaping (Data) -> Void) { source = image; imageView = UIImageView(image: image); self.done = done; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "moments.cropCover" }
    override var body: Layout { scroll.resizable().frame(width: max(0, view.bounds.width - 32), height: max(100, (view.bounds.width - 32) / 2)).safeAreaPadding(.all, 0) }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground; scroll.delegate = self; scroll.clipsToBounds = true
        scroll.addSubview(imageView); scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); navigationItem.rightBarButtonItem = UIBarButtonItem(title: Localization.text("moments.usePhoto"), primaryAction: UIAction { [weak self] _ in self?.commit() })
    }
    /// 在裁剪窗口尺寸变化后重算最小缩放，保留源图坐标下的中心与相对放大倍数。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.bounds.size != previousSize, source.size.width > 0, scroll.bounds.width > 0 else { return }
        let center = CGPoint(x: (scroll.contentOffset.x + previousSize.width / 2) / max(scroll.zoomScale, 0.001), y: (scroll.contentOffset.y + previousSize.height / 2) / max(scroll.zoomScale, 0.001))
        let relativeZoom = scroll.zoomScale / max(scroll.minimumZoomScale, 0.001)
        let initialized = previousSize != .zero; previousSize = scroll.bounds.size
        // UIScrollView 负责缩放变换，源图 frame 必须在缩放归一后重设。
        scroll.minimumZoomScale = min(1, scroll.minimumZoomScale); scroll.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: source.size); scroll.contentSize = source.size
        let minimum = max(scroll.bounds.width / source.size.width, scroll.bounds.height / source.size.height)
        scroll.minimumZoomScale = minimum; scroll.maximumZoomScale = minimum * 5; scroll.zoomScale = minimum * min(5, max(1, relativeZoom))
        let point = initialized ? center : CGPoint(x: source.size.width / 2, y: source.size.height / 2)
        scroll.contentOffset = CGPoint(x: max(0, min(scroll.contentSize.width - scroll.bounds.width, point.x * scroll.zoomScale - scroll.bounds.width / 2)), y: max(0, min(scroll.contentSize.height - scroll.bounds.height, point.y * scroll.zoomScale - scroll.bounds.height / 2)))
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    /// 将可见裁剪窗口映射为 1600 × 800 像素 JPEG，成功后回调并返回上一页。
    private func commit() {
        guard scroll.bounds.width > 0 else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: 1600, height: 800)
        let cropped = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let factor = size.width / scroll.bounds.width
            context.cgContext.scaleBy(x: factor, y: factor)
            context.cgContext.translateBy(x: -scroll.contentOffset.x, y: -scroll.contentOffset.y)
            source.draw(in: CGRect(origin: .zero, size: CGSize(width: source.size.width * scroll.zoomScale, height: source.size.height * scroll.zoomScale)))
        }
        if let bytes = cropped.jpegData(compressionQuality: 0.9) { done(bytes); navigationController?.popViewController(animated: true) }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("封面裁剪") { MomentsCoverCropController(image: UIImage(systemName: "photo")!, done: { _ in }) }
#endif
