import QuickLayout
import QuickLayoutKit
import UIKit

final class LiveTextBubble: QuickLayoutView {
    let label = UILabel()
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        clipsToBounds = true
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout { label.resizable(axis: .horizontal).padding(12) }
}
