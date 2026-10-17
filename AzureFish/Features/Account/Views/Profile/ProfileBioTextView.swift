import UIKit

/// 在给定容器宽度内测量全部简介，滚动交由页面统一处理。
final class ProfileBioTextView: UITextView {
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // QuickLayout 对未重写此方法的 UITextView 直接采用建议尺寸，不能反映长文本高度。
        let width = size.width.isFinite && size.width > 0 ? size.width : max(1, bounds.width)
        let fitted = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(144, ceil(fitted.height)))
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("个人简介 · 长文本") {
    let view = ProfileBioTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.isScrollEnabled = false
    view.text = String(repeating: "A long profile. 個人資料。", count: 20)
    return view
}
#endif
