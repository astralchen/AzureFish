//
//  MediaDraftStripView.swift
//  Demo
//

import AVKit
import AppLocalization
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 草稿外观配置，由输入栏和卡片共享。
nonisolated enum MediaDraftAppearance {
    static let itemHeight: CGFloat = 156
    static let minimumWidth: CGFloat = 80
    static let maximumWidth: CGFloat = 208
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 2
}

/// 媒体像素比例到展示尺寸的转换，不属于 collection layout。
nonisolated enum MediaDraftItemSizing {
    static func size(for pixelSize: CGSize?) -> CGSize {
        let height = MediaDraftAppearance.itemHeight
        guard let pixelSize, pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: MediaDraftAppearance.minimumWidth, height: height)
        }
        let width = min(MediaDraftAppearance.maximumWidth,
                        max(MediaDraftAppearance.minimumWidth, height * (pixelSize.width / pixelSize.height)))
        return CGSize(width: width, height: height)
    }
}

/// 按选择顺序显示媒体草稿；QuickLayout 管理容器，collection layout 管理项目几何。
final class MediaDraftStripView: QuickLayoutView, MediaDraftCollectionViewLayoutDelegate {
    let draftLayout = MediaDraftCollectionViewLayout()
    let collectionView: UICollectionView
    /// 保留滚动容器访问入口，调用者无需依赖 collection view 的实现。
    var scrollView: UIScrollView { collectionView }
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private var displayedItems: [MediaDraftItemPresentation] = []
    private var latestItems: [MediaDraftItemPresentation] = []
    private var strings: MediaStrings?
    private var appliedStrings: MediaStrings?
    private var isApplying = false
    private var hasPendingUpdate = false
    private var pendingAnimated = false
    private var pendingScrollID: UUID?
    private var itemSizes: [UUID: CGSize] = [:]
    private var awaitingVideoGeometry: Set<UUID> = []
    var isUpdatingPresentation: Bool { isApplying || hasPendingUpdate || pendingScrollID != nil }

    var removeRequested: ((UUID) -> Void)?
    var previewRequested: ((UUID) -> Void)?

    /// 全量几何来自 layout，不要求离屏项目实例化。
    var renderedItemFrames: [CGRect] {
        collectionView.layoutIfNeeded()
        return dataSource.snapshot().itemIdentifiers.indices.compactMap {
            draftLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
    }
    var renderedItemIDs: [UUID] { dataSource.snapshot().itemIdentifiers }
    var livePhotoBadgeItemIDs: Set<UUID> {
        Set(displayedItems.compactMap { $0.mediaItem?.isLivePhoto == true ? $0.id : nil })
    }

    override init(frame: CGRect) {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: draftLayout)
        super.init(frame: frame)
        clipsToBounds = true
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = .zero
        draftLayout.itemSize = MediaDraftItemSizing.size(for: nil)
        draftLayout.minimumLineSpacing = MediaDraftAppearance.spacing
        draftLayout.sectionInset = UIEdgeInsets(top: 0, left: MediaDraftAppearance.horizontalInset,
                                               bottom: 0, right: MediaDraftAppearance.horizontalInset)
        collectionView.isPrefetchingEnabled = false
        collectionView.register(DraftCell.self, forCellWithReuseIdentifier: "draft")
        dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] collection, indexPath, id in
            guard let self, let strings = appliedStrings,
                  let order = displayedItems.firstIndex(where: { $0.id == id }),
                  let cell = collection.dequeueReusableCell(withReuseIdentifier: "draft", for: indexPath) as? DraftCell else { return nil }
            let item = displayedItems[order]
            // 新 cell 已由插入/输入栏展开负责入场；只有已有占位的内容回填再淡入。
            cell.itemView.imageView.thumbnailFadeDuration = cell.representedID == id ? 0.16 : 0
            cell.representedID = id
            if awaitingVideoGeometry.contains(id) { cell.itemView.imageView.isContentActive = false }
            cell.itemView.configure(item, order: order, totalCount: displayedItems.count, strings: strings)
            cell.itemView.removeRequested = { [weak self] in
                guard let self, latestItems.contains(where: { $0.id == id }) else { return }
                removeRequested?(id)
            }
            cell.itemView.previewRequested = { [weak self] in
                guard let self, latestItems.contains(where: { $0.id == id && $0.mediaItem != nil }) else { return }
                previewRequested?(id)
            }
            return cell
        }
        accessibilityIdentifier = "imessage.composer.mediaStrip"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 首张入场时外层从零高度展开，collection 保持完整卡片尺寸并贴住底边。
    // 裁剪区域随输入栏揭开，卡片不会穿过下方文本行，也不拉伸缩略图。
    override var body: Layout {
        collectionView.resizable(axis: .horizontal)
            .frame(height: MediaDraftAppearance.itemHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
    }

    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            collectionView.semanticContentAttribute = semanticContentAttribute
            draftLayout.invalidateGeometry()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        revealPendingItem()
        updateVisibleThumbnails()
    }

    func previewSource(id: UUID) -> UIView? {
        guard latestItems.contains(where: { $0.id == id && $0.mediaItem != nil }),
              let index = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: index) as? DraftCell,
              cell.representedID == id, cell.frame.intersects(collectionView.bounds) else { return nil }
        return cell.itemView
    }

    func configure(_ draft: MediaDraftPresentation?, strings: MediaStrings, animated: Bool = true) {
        latestItems = draft?.visibleItems ?? []
        self.strings = strings
        pendingAnimated = animated && window != nil && UIView.areAnimationsEnabled && !UIAccessibility.isReduceMotionEnabled
        hasPendingUpdate = true
        applyPendingUpdate()
    }

    /// 一次只应用一个快照；导入期间的中间状态合并，业务动作始终读取最新状态。
    private func applyPendingUpdate() {
        guard !isApplying, hasPendingUpdate, let strings else { return }
        hasPendingUpdate = false
        let next = latestItems
        guard next != displayedItems || strings != appliedStrings else {
            revealPendingItem()
            return
        }
        let animated = pendingAnimated
        collectionView.layoutIfNeeded()
        let old = displayedItems
        let nextIDs = Set(next.map(\.id))
        let oldIDs = Set(old.map(\.id))
        // 较早选择的视频可能晚于后面的照片就绪；插入后仍显示选择顺序的末项。
        let added = next.contains(where: { !oldIDs.contains($0.id) }) ? next.last?.id : nil
        // 首个存续可见项目作为锚点，宽度变化或删除前项时保留屏幕坐标。
        let visibleAnchor = old.enumerated().first { index, item in
            nextIDs.contains(item.id) && (draftLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.intersects(collectionView.bounds) == true)
        }.map { index, item in
            (id: item.id, x: draftLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame.minX - collectionView.contentOffset.x)
        }
        let rtl = collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let atEnd = rtl
            ? collectionView.contentOffset.x <= -collectionView.adjustedContentInset.left + 1
            : collectionView.contentOffset.x >= max(-collectionView.adjustedContentInset.left,
                collectionView.contentSize.width - collectionView.bounds.width + collectionView.adjustedContentInset.right) - 1
        let anchor: MediaDraftCollectionViewLayout.Anchor?
        if let added, let index = next.firstIndex(where: { $0.id == added }) {
            anchor = .init(indexPath: IndexPath(item: index, section: 0), alignment: .trailing)
        } else if old.map(\.id) == next.map(\.id), atEnd,
                  !collectionView.isDragging, !collectionView.isDecelerating, !next.isEmpty {
            anchor = .init(indexPath: IndexPath(item: next.count - 1, section: 0), alignment: .trailing)
        } else if let visibleAnchor, let index = next.firstIndex(where: { $0.id == visibleAnchor.id }) {
            anchor = .init(indexPath: IndexPath(item: index, section: 0), alignment: .screenPosition(visibleAnchor.x))
        } else {
            anchor = nil
        }
        let nextSizes = Dictionary(uniqueKeysWithValues: next.map {
            ($0.id, MediaDraftItemSizing.size(for: $0.displaySize))
        })
        // 不让首张视频画面在未知比例的窄占位中解码或参与变宽动画。
        // 已知比例直接用于占位；未知比例先落定最终几何，再激活缩略图。
        awaitingVideoGeometry = Set(next.compactMap { item in
            guard let media = item.mediaItem, case .video = media.kind,
                  let previous = old.first(where: { $0.id == item.id }), previous.mediaItem == nil,
                  itemSizes[item.id] != nextSizes[item.id] else { return nil }
            return item.id
        })
        let animateWidthChange = animated && awaitingVideoGeometry.isEmpty
        displayedItems = next
        let stringsChanged = appliedStrings != strings
        appliedStrings = strings
        draftLayout.reducesMotion = UIAccessibility.isReduceMotionEnabled
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(next.map(\.id))
        snapshot.reconfigureItems(next.enumerated().compactMap { index, item in
            guard let oldIndex = old.firstIndex(where: { $0.id == item.id }) else { return nil }
            return stringsChanged || old[oldIndex] != item || oldIndex != index || old.count != next.count ? item.id : nil
        })
        if let added {
            pendingScrollID = added
        } else if let pendingScrollID, !nextIDs.contains(pendingScrollID) {
            self.pendingScrollID = nil
        }
        isApplying = true
        let completion: () -> Void = { [weak self] in
            guard let self else { return }
            isApplying = false
            collectionView.layoutIfNeeded()
            if let anchor, let offset = draftLayout.contentOffset(for: anchor) {
                collectionView.contentOffset = offset
            }
            draftLayout.finishUpdates()
            awaitingVideoGeometry.removeAll()
            updateVisibleThumbnails()
            if !hasPendingUpdate { revealPendingItem() }
            applyPendingUpdate()
        }
        if old.map(\.id) == next.map(\.id) {
            // reconfigureItems 本身不会为自定义 layout 的宽度生成过渡。
            // 先保留旧几何更新内容，再在独立的布局事务里动画失效尺寸。
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                collectionView.layoutIfNeeded()
                let sizeChanged = itemSizes != nextSizes
                itemSizes = nextSizes
                draftLayout.updateAnchor = anchor
                let changes = { [self] in draftLayout.invalidateMetrics() }
                if animateWidthChange && sizeChanged {
                    collectionView.performBatchUpdates(changes) { _ in completion() }
                } else {
                    UIView.performWithoutAnimation {
                        changes()
                        collectionView.layoutIfNeeded()
                    }
                    completion()
                }
            }
        } else {
            itemSizes = nextSizes
            draftLayout.updateAnchor = anchor
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        setNeedsLayout()
    }

    private func revealPendingItem() {
        guard !isApplying, !hasPendingUpdate, collectionView.bounds.width > 0,
              let id = pendingScrollID, let index = dataSource.indexPath(for: id),
              let offset = draftLayout.contentOffset(for: .init(indexPath: index, alignment: .trailing)) else { return }
        pendingScrollID = nil
        collectionView.setContentOffset(offset, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisibleThumbnails() }

    func collectionView(_ collectionView: UICollectionView, layout: MediaDraftCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return layout.itemSize }
        return itemSizes[id] ?? layout.itemSize
    }

    private func updateVisibleThumbnails() {
        for case let cell as DraftCell in collectionView.visibleCells {
            cell.itemView.imageView.isContentActive = cell.frame.intersects(collectionView.bounds)
                && cell.representedID.map { !awaitingVideoGeometry.contains($0) } == true
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? DraftCell else { return }
        // 首次加入时先排好图片、圆角和角标，避免内部从零尺寸继承父级展开动画。
        UIView.performWithoutAnimation {
            cell.setNeedsQuickLayout()
            cell.quickLayoutIfNeeded()
            cell.itemView.quickLayoutIfNeeded()
        }
        cell.itemView.imageView.isContentActive = cell.frame.intersects(collectionView.bounds)
            && cell.representedID.map { !awaitingVideoGeometry.contains($0) } == true
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? DraftCell)?.itemView.imageView.isContentActive = false
    }

    private final class DraftCell: QuickLayoutCollectionViewCell {
        let itemView = DraftItemView()
        var representedID: UUID?
        override var quickLayoutDirectionViews: [UIView] { [self, contentView, itemView] }
        override var body: Layout { itemView.resizable() }
        override init(frame: CGRect) {
            super.init(frame: frame)
            itemView.imageView.isContentActive = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func prepareForReuse() {
            super.prepareForReuse()
            representedID = nil
            itemView.reset()
        }
    }

    /// 显示单个媒体草稿缩略图、导入状态和删除入口的视图。
    private final class DraftItemView: QuickLayoutView {
        /// 显示当前媒体图像的图像视图。
        let imageView = MediaImageView()
        /// 媒体原件尚在导入时显示的活动指示器。
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        /// 标示草稿为视频的图像视图。
        let videoBadge = UIImageView()
        /// 视频时长的深色半透明底衬，使白色文字在明亮封面上保持可读。
        lazy var durationBackgroundView = QuickLayoutView { [unowned self] in
            durationLabel.fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
        }
        /// 显示视频时长的标签。
        let durationLabel = UILabel()
        /// 仅实况照片显示的角标背景容器。
        let livePhotoBadgeView = UIView()
        /// 标示实况照片的符号视图；GIF 和普通图片不显示。
        let livePhotoBadgeImageView = UIImageView()
        /// 删除当前媒体草稿项目的按钮。
        let removeButton = DraftRemoveButton(frame: .zero)
        /// 用户点击本项目删除按钮时调用的闭包。
        var removeRequested: (() -> Void)?
        /// 已就绪项目的打开动作；导入期间不触发。
        var previewRequested: (() -> Void)?
        private var isReady = false


        /// 使用指定初始边框创建 `DraftItemView`，并配置其子视图和默认外观。
        ///
        /// - Parameter frame: 在父视图坐标系中指定的初始边框。
        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.cornerRadius = 14
            layer.cornerCurve = .continuous
            backgroundColor = .secondarySystemFill

            imageView.thumbnailFadeDuration = 0.16
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = true
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(previewTapped)))

            activityIndicator.hidesWhenStopped = true

            videoBadge.image = UIImage(systemName: "video.fill")
            videoBadge.tintColor = .white
            videoBadge.contentMode = .scaleAspectFit

            durationBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            durationBackgroundView.layer.cornerRadius = 5
            durationBackgroundView.layer.cornerCurve = .continuous
            durationBackgroundView.isUserInteractionEnabled = false

            durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            durationLabel.textColor = .white

            livePhotoBadgeView.isHidden = true
            livePhotoBadgeView.isUserInteractionEnabled = false
            livePhotoBadgeImageView.isHidden = true
            livePhotoBadgeImageView.accessibilityIdentifier = "imessage.composer.media.livePhotoBadge"
            livePhotoBadgeView.backgroundColor = .white
            livePhotoBadgeView.layer.cornerRadius = 13
            livePhotoBadgeView.layer.cornerCurve = .continuous
            livePhotoBadgeImageView.image = UIImage(
                systemName: "livephoto",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 18,
                    weight: .regular
                )
            )
            livePhotoBadgeImageView.tintColor = .systemBlue
            livePhotoBadgeImageView.contentMode = .scaleAspectFit

            removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        }

        /// 不支持从归档创建 `DraftItemView`。
        ///
        /// 请使用代码初始化方法创建此对象。
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 图片、角标和命中区域全部由 QuickLayout 声明式排版。
        override var body: Layout {
            ZStack {
                imageView.resizable()
                activityIndicator.frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                removeButton.frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                if !livePhotoBadgeView.isHidden {
                    ZStack {
                        livePhotoBadgeView.resizable()
                        livePhotoBadgeImageView.resizable().padding(4)
                    }
                    .frame(width: 26, height: 26)
                    .padding(.leading, 6).padding(.top, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if !videoBadge.isHidden {
                    videoBadge.resizable().frame(width: 17, height: 12)
                        .padding(.leading, 12).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    durationBackgroundView.fixedSize()
                    .padding(.trailing, 4).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }

        func reset() {
            alpha = 1
            imageView.isContentActive = false
            imageView.setThumbnail(nil)
            imageView.layer.removeAllAnimations()
            imageView.isAccessibilityElement = false
            imageView.accessibilityIdentifier = nil
            activityIndicator.stopAnimating()
            livePhotoBadgeView.isHidden = true
            livePhotoBadgeImageView.isHidden = true
            videoBadge.isHidden = true
            durationLabel.isHidden = true
            durationBackgroundView.isHidden = true
            accessibilityLabel = nil
            removeRequested = nil
            previewRequested = nil
            isReady = false
        }

        /// 应用媒体导入状态、缩略图、序号及可访问的类型和位置说明。
        func configure(
            _ item: MediaDraftItemPresentation,
            order: Int,
            totalCount: Int,
            strings: MediaStrings
        ) {
            imageView.isAccessibilityElement = false
            imageView.accessibilityIdentifier = nil
            videoBadge.isHidden = true
            durationLabel.isHidden = true
            durationBackgroundView.isHidden = true
            livePhotoBadgeView.isHidden = true
            livePhotoBadgeImageView.isHidden = true
            isReady = false
            switch item.content {
            case .importing:
                imageView.setThumbnail(nil)
                activityIndicator.startAnimating()
                accessibilityLabel = strings.importing
            case .ready(let media):
                isReady = true
                imageView.isAccessibilityElement = true
                imageView.accessibilityTraits = .button
                imageView.accessibilityIdentifier = "imessage.composer.media.preview.\(item.id.uuidString)"
                imageView.accessibilityLabel = strings.openPreview
                activityIndicator.stopAnimating()
                imageView.setThumbnail(media.thumbnailFileURL)
                let position = String(
                    format: strings.positionFormat,
                    order + 1,
                    totalCount
                )
                switch media.kind {
                case .image:
                    livePhotoBadgeView.isHidden = !media.isLivePhoto
                    livePhotoBadgeImageView.isHidden = !media.isLivePhoto
                    let imageDescription = media.isLivePhoto
                        ? Localization.text("imessage.media.livePhoto")
                        : media.isAnimatedImage ? strings.animatedImage : strings.image
                    accessibilityLabel = "\(position), \(imageDescription)"
                case .video(let duration):
                    videoBadge.isHidden = false
                    durationLabel.isHidden = false
                    durationBackgroundView.isHidden = false
                    durationLabel.text = Self.durationText(duration)
                    let videoDescription = String(
                        format: strings.videoDurationFormat,
                        durationLabel.text ?? ""
                    )
                    accessibilityLabel = "\(position), \(videoDescription)"
                }
            }
            durationBackgroundView.setNeedsQuickLayout()
            removeButton.accessibilityIdentifier = "imessage.composer.media.remove.\(item.id.uuidString)"
            removeButton.accessibilityLabel = strings.remove
            accessibilityIdentifier = "imessage.composer.media.\(item.id.uuidString)"
            setNeedsQuickLayout()
        }

        /// 将删除按钮事件转发给项目删除回调。
        /// 打开当前媒体，保留独立删除按钮的命中区域。
        @objc private func previewTapped() { if isReady { previewRequested?() } }
        @objc private func removeTapped() {
            removeRequested?()
        }

        /// 将秒数格式化为分钟和两位秒数的视频时长文本。
        private static func durationText(_ duration: TimeInterval) -> String {
            let seconds = max(0, Int(duration.rounded()))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}
