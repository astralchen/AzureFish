import UIKit

/// 为整个成员分组提供连续的语义背景。
final class ConversationMembersBackground: UICollectionReusableView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .secondarySystemGroupedBackground }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("成员分组背景") { ConversationMembersBackground(frame: CGRect(x: 0, y: 0, width: 390, height: 120)) }
#endif
