//
//  MediaMessageView.swift
//  Demo
//

import AVKit
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 显示单张媒体或可横向切换的媒体堆叠的消息视图。
final class MediaMessageView: QuickLayoutView, UIGestureRecognizerDelegate {
    /// 单张媒体气泡与多媒体堆叠共用的布局尺寸。
    enum Metrics {
        /// 单张媒体允许的最大宽度，单位为点。
        static let singleMaximumWidth: CGFloat = 252
        /// 单张媒体允许的最大高度，单位为点。
        static let singleMaximumHeight: CGFloat = 360
        /// 单张媒体布局的最小边长约束，单位为点。
        static let singleMinimumEdge: CGFloat = 120
        /// 媒体堆叠中每张卡片的基准尺寸。
        static let groupCardSize = CGSize(width: 216, height: 300)
        /// 媒体堆叠相邻层的水平与垂直偏移量。
        static let groupOffset = CGPoint(x: 8, y: 6)
        /// 测量与绘制共用旋转角，保证背面卡片的外接矩形计入消息高度。
        static func groupRotationAngle(depth: Int) -> CGFloat {
            min(4, CGFloat(depth) * 1.2) * .pi / 180
        }
        /// 媒体数量标题行的高度，单位为点。
        static let titleHeight: CGFloat = 24
        /// 媒体数量标题与堆叠卡片之间的间距，单位为点。
        static let titleSpacing: CGFloat = 8
        /// 媒体卡片的圆角半径，单位为点。
        static let cornerRadius: CGFloat = 22
        /// 单张气泡在尾部一侧额外预留的宽度。
        static let singleTailWidth: CGFloat = 13
    }

    /// 显示媒体组总项目数的标签。
    let itemCountLabel = UILabel()
    /// 与项目数量配套显示的媒体网格符号。
    let itemCountIcon = UIImageView(image: UIImage(systemName: "square.grid.2x2.fill"))
    /// 裁剪单张媒体气泡轮廓的形状遮罩。
    let singleMaskView = QuickLayoutShapeView(frame: .zero)
    /// 用于显示有限媒体窗口的可复用卡片集合。
    var cards: [CardView] = []
    /// 驱动媒体封面切换的水平拖动手势。
    lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    /// 打开被点击媒体项目预览的轻点手势。
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

    /// 当前媒体消息的稳定标识符。
    var messageID = 0
    /// 当前消息的接收或发出方向，用于确定气泡外观与语义对齐。
    var direction: MessageDirection = .incoming
    /// 当前显示的有序媒体组；未配置或重置后为 `nil`。
    var group: MediaGroupAttachment?
    /// 当前媒体内容的本地化文字集合。
    var strings: MediaStrings?
    /// 当前位于堆叠最前方的媒体项目索引。
    var frontMediaIndex = 0
    /// 指示封面切换动画尚未结束的布尔值，用于限制手势重入。
    var isAnimating = false
    /// 当前尚未提交的拖动预览；收尾和静止阶段为 `nil`。
    var interaction: MediaStackPolicy.Interaction?
    /// 使取消、重新绑定之前的动画完成回调失效的递增令牌。
    var transitionGeneration: UInt = 0
    /// 最近布局使用的边界尺寸，用于取消几何已失效的交互。
    private var laidOutSize: CGSize = .zero
    /// 最近布局使用的界面方向；变化后重新建立静止几何。
    private var laidOutDirection: UIUserInterfaceLayoutDirection?
    /// 根据当前单张媒体或堆叠内容计算的固有尺寸。
    var resolvedSize = CGSize(width: 252, height: 252)

    /// 封面位置改变后调用的闭包，参数依次为消息身份与媒体索引。
    var frontIndexDidChange: ((Int, Int) -> Void)?
    /// 用户请求预览媒体时调用的闭包，参数为消息身份、媒体组与起始索引。
    var previewRequested: ((Int, MediaGroupAttachment, Int) -> Void)?

    /// 多张媒体才显示数量标题，并启用卡片堆叠布局。
    var hasMultipleItems: Bool { (group?.items.count ?? 0) > 1 }

    /// 标题与卡片共享宿主坐标；卡片的旋转和拖动仍由交互状态驱动。
    override var body: Layout {
        ZStack {
            if hasMultipleItems {
                itemCountIcon.resizable()
                    .frame(width: 18, height: 18)
                    .position(x: titleOriginX + 9, y: 11)
                itemCountLabel.resizable()
                    .frame(width: 90, height: Metrics.titleHeight)
                    .position(x: titleOriginX + 67, y: Metrics.titleHeight / 2)
            }
            for card in cards where !card.isHidden {
                card.resizable()
                    .frame(width: card.restingFrame.width, height: card.restingFrame.height)
                    .position(x: card.restingFrame.midX, y: card.restingFrame.midY)
            }
        }
    }

    /// 数量标题沿消息的物理外侧对齐，保留图标在文字左侧的排列。
    private var titleOriginX: CGFloat {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let atRightEdge = direction == .outgoing ? !isRTL : isRTL
        return atRightEdge ? bounds.width - 112 : 0
    }

    /// 从当前封面生成匹配转场，不包含背后的堆叠卡片。
    var previewSourceView: UIView? {
        guard let group, group.items.indices.contains(frontMediaIndex) else { return nil }
        return cards.first { $0.represents(messageID: messageID, groupID: group.id, itemID: group.items[frontMediaIndex].id) }
    }

    /// 使用指定初始边框创建 `MediaMessageView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        clipsToBounds = false
        itemCountLabel.font = .preferredFont(forTextStyle: .headline)
        itemCountLabel.adjustsFontForContentSizeCategory = true
        itemCountLabel.textColor = .systemBlue
        itemCountLabel.textAlignment = .natural
        itemCountIcon.tintColor = .systemBlue
        singleMaskView.fillColor = .black
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
        tapGesture.require(toFail: panGesture)
        addGestureRecognizer(tapGesture)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button, .adjustable]
        accessibilityIdentifier = "imessage.media.message"
    }

    /// 不支持从归档创建 `MediaMessageView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `MediaMessageView` 在当前内容与布局约束下的固有尺寸。
    override var intrinsicContentSize: CGSize { resolvedSize }

    /// 标题不随媒体卡片缩放，保存按钮与卡片共用此高度。
    var headerHeight: CGFloat {
        hasMultipleItems ? Metrics.titleHeight + Metrics.titleSpacing : 0
    }

    /// 直接响应 stack 分配的宽度，首次测量不依赖 bounds 或历史布局属性。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let scale = min(1, max(0, size.width) / max(1, resolvedSize.width))
        return CGSize(width: resolvedSize.width * scale,
                      height: headerHeight + (resolvedSize.height - headerHeight) * scale)
    }

    override func quick_flexibility(for axis: Axis) -> Flexibility {
        axis == .horizontal ? .partial : .fixedSize
    }

    /// 根据当前边界更新 `MediaMessageView` 的子视图布局与图层几何。
    override func layoutSubviews() {
        if laidOutSize != bounds.size || laidOutDirection != effectiveUserInterfaceLayoutDirection {
            invalidateInteraction()
            laidOutSize = bounds.size
            laidOutDirection = effectiveUserInterfaceLayoutDirection
            bindCards()
        }
        guard !isAnimating else {
            super.layoutSubviews()
            return
        }
        layoutCards()
        applyInteraction()
    }

    /// 先更新静止几何，再让 QuickLayout 放置卡片；动画收尾也复用此入口。
    func layoutCards() {
        updateCardGeometry()
        super.layoutSubviews()
        updateSingleMask()
    }

    /// 离开窗口时取消尚未确认的拖动，并清理正在收尾的动画。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            invalidateInteraction()
            bindCards()
            layoutCards()
        }
    }

    /// 绑定有序媒体组与封面位置，更新卡片数量、固有尺寸和辅助功能信息。
    func configure(
        messageID: Int,
        direction: MessageDirection,
        group: MediaGroupAttachment,
        frontIndex: Int,
        strings: MediaStrings
    ) {
        let resolvedIndex = min(max(0, frontIndex), max(0, group.items.count - 1))
        let keepsBinding = self.messageID == messageID && self.group == group
            && self.direction == direction && frontMediaIndex == resolvedIndex
        if !keepsBinding { invalidateInteraction() }
        self.messageID = messageID
        self.direction = direction
        self.group = group
        self.strings = strings
        frontMediaIndex = resolvedIndex
        ensureCardCount(
            min(
                group.items.count,
                MediaStackPolicy.maximumVisibleCardCount
            )
        )
        let previousSize = resolvedSize
        resolvedSize = Self.size(for: group)
        if previousSize != resolvedSize { invalidateIntrinsicContentSize() }
        panGesture.isEnabled = group.items.count > 1
        itemCountLabel.text = String(format: strings.itemsFormat, group.items.count)
        accessibilityValue = String(
            format: strings.positionFormat,
            frontMediaIndex + 1,
            group.items.count
        )
        accessibilityHint = strings.openPreview
        updateAccessibilityLabel()
        if interaction == nil && !isAnimating { bindCards() }
        setNeedsQuickLayout()
    }

    /// 清空媒体绑定、标题、遮罩和辅助功能状态，并重置全部卡片。
    func reset() {
        invalidateInteraction()
        group = nil
        strings = nil
        messageID = 0
        frontMediaIndex = 0
        isAnimating = false
        itemCountLabel.text = nil
        singleMaskView.shape = nil
        singleMaskView.layoutIfNeeded()
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        cards.forEach { $0.reset(); $0.isHidden = true }
        panGesture.isEnabled = false
        setNeedsQuickLayout()
    }

    /// 通过辅助功能递增操作切换到下一媒体项目。
    override func accessibilityIncrement() {
        move(to: frontMediaIndex + 1, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 通过辅助功能递减操作切换到上一媒体项目。
    override func accessibilityDecrement() {
        move(to: frontMediaIndex - 1, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 仅在有多个项目、没有切换动画且手势以水平运动为主时允许拖动。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture,
              let group,
              group.items.count > 1,
              !isAnimating, interaction == nil else { return false }
        let velocity = panGesture.velocity(in: self)
        return MediaStackPolicy.isHorizontalPan(velocity: velocity)
    }

    /// 返回当前已绑定媒体卡片的布局 frame，供页面内布局回归测试使用。
    func visibleCardFrame(forMediaIndex index: Int) -> CGRect? {
        cards.first { !$0.isHidden && $0.mediaIndex == index }?.restingFrame
    }

    /// 返回当前已绑定媒体卡片的展示层级，供页面内布局回归测试使用。
    func visibleCardZPosition(forMediaIndex index: Int) -> CGFloat? {
        cards.first { !$0.isHidden && $0.mediaIndex == index }?.layer.zPosition
    }

    /// 返回当前已绑定媒体卡片的静态扇形变换。
    func visibleCardRestingTransform(forMediaIndex index: Int) -> CGAffineTransform? {
        cards.first { !$0.isHidden && $0.mediaIndex == index }?.restingTransform
    }

    /// 返回包含当前交互缩放和旋转的卡片变换，供交互回归测试使用。
    func visibleCardTransform(forMediaIndex index: Int) -> CGAffineTransform? {
        cards.first { !$0.isHidden && $0.mediaIndex == index }?.transform
    }

    /// 返回当前交互卡片的中心位置，供连续拖动和布局回归测试使用。
    func visibleCardCenter(forMediaIndex index: Int) -> CGPoint? {
        cards.first { !$0.isHidden && $0.mediaIndex == index }?.center
    }

    /// 当前参与展示的卡片层数。
    var visibleCardCount: Int {
        cards.lazy.filter { !$0.isHidden }.count
    }

    /// 返回指定媒体当前绑定的 CardView 身份，供重用回归测试使用。
    func visibleCardObjectIdentifier(forMediaIndex index: Int) -> ObjectIdentifier? {
        cards.first { !$0.isHidden && $0.mediaIndex == index }.map(ObjectIdentifier.init)
    }
}
