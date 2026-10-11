import QuickLayout
import QuickLayoutKit
import UIKit

/// 续页组件的显示状态；点击行为和整行无障碍描述由列表 Cell 配置。
struct MomentsPaginationConfiguration: UIContentConfiguration {
    let state: MomentsPaginationState
    func makeContentView() -> UIView & UIContentView { MomentsPaginationView(configuration: self) }
    func updated(for state: UIConfigurationState) -> Self { self }
}

/// 使用独立复用池，避免页脚的整行无障碍状态覆盖动态内的图片和互动控件。
final class MomentsPaginationCell: UICollectionViewListCell {}

/// 无列表分隔线的居中页脚；空闲时留白，加载时显示系统转轮，结束时显示短线。
final class MomentsPaginationView: QuickLayoutContentView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let line = UIView()
    private var state: MomentsPaginationState = .idle
    override init(configuration: any UIContentConfiguration) {
        super.init(configuration: configuration)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel; label.numberOfLines = 0; label.textAlignment = .center
        label.isAccessibilityElement = false; spinner.isAccessibilityElement = false
        line.backgroundColor = .separator
        applyCurrentContentConfiguration()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(spacing: 8) {
            if state == .loading { spinner.frame(width: 20, height: 20) }
            if state == .failed { label.resizable(axis: .horizontal) }
            if state == .ended { line.frame(width: 36, height: 1) }
        }.padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: .infinity, minHeight: 64)
    }
    override func applyContentConfiguration(_ configuration: any UIContentConfiguration) {
        guard let configuration = configuration as? MomentsPaginationConfiguration else { return }
        state = configuration.state; label.text = state.label
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈续页 Cell") {
    let cell = MomentsPaginationCell(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
    cell.contentConfiguration = MomentsPaginationConfiguration(state: .loading)
    return cell
}
@available(iOS 17.0, *)
#Preview("朋友圈续页 · 加载／重试／结束") {
    QuickLayoutHostingController {
        VStack(spacing: 0) {
            MomentsPaginationView(configuration: MomentsPaginationConfiguration(state: .loading)).resizable(axis: .horizontal)
            MomentsPaginationView(configuration: MomentsPaginationConfiguration(state: .failed)).resizable(axis: .horizontal)
            MomentsPaginationView(configuration: MomentsPaginationConfiguration(state: .ended)).resizable(axis: .horizontal)
        }
    }
}
#endif
