//
//  ChatMediaTests.swift
//  DemoTests
//
//  验证 UIKit 照片、视频消息及输入栏联动行为。
//

import CoreGraphics
import Foundation
import PhotosUI
import Testing
import UIKit
import QuickLayoutKit
@_spi(Testing) import QuickLayoutKitUIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatMediaTests {
    /// 实际卡片遮罩在尾部与主体相接处必须保持不透明，收发方向与 RTL 一并覆盖。
    @Test(arguments: [false, true])
    func singleMediaBubbleHasNoTransparentTailSeam(isVideo: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 2, videoIndices: isVideo ? [0] : [])
        defer { fixture.remove() }
        let group = MediaGroupAttachment(items: [fixture.group.items[0]])
        let view = makeStackView(group)
        for size in [CGSize(width: 252, height: 360), CGSize(width: 252, height: 163),
                     CGSize(width: 120, height: 172)] {
            for direction in [MessageDirection.incoming, .outgoing] {
                for rtl in [false, true] {
                    view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    view.configure(messageID: 8, direction: direction, group: group,
                                   frontIndex: 0, strings: mediaStrings)
                    view.frame.size = size
                    view.setNeedsLayout()
                    view.layoutIfNeeded()
                    let card = try #require(view.frontCard)
                    card.imageView.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.20, alpha: 1)
                    #expect(card.mask === view.singleMaskView)
                    let layer = try #require(view.singleMaskView.layer as? CAShapeLayer)
                    let path = try #require(layer.path)
                    let previewPath = try #require(view.menuPreviewPath)
                    #expect(previewPath.cgPath == path, "菜单轮廓必须与真实单图遮罩完全一致")
                    let tailOnRight = direction == .outgoing ? !rtl : rtl
                    // 截图中缺口位于主体内、距离尾部边缘约 20pt 的位置。
                    for x in 20...26 {
                        for bottomInset in 10...18 {
                            let point = CGPoint(x: tailOnRight ? size.width - CGFloat(x) : CGFloat(x),
                                                y: size.height - CGFloat(bottomInset))
                            #expect(path.contains(point), "气泡主体与尾巴的连接处不能穿透：\(point)")
                        }
                    }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 2
                    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
                        UIColor.white.setFill()
                        context.fill(view.bounds)
                        view.layer.render(in: context.cgContext)
                    }
                    // 检查最终卡片像素，既覆盖遮罩缺口，也覆盖卡片圆角二次裁剪尾尖。
                    for probe in [CGPoint(x: 20, y: size.height - 14), CGPoint(x: 5, y: size.height - 4)] {
                        let x = tailOnRight ? size.width - probe.x : probe.x
                        let pixel = try #require(image.cgImage?.cropping(to:
                            CGRect(x: x * 2, y: probe.y * 2, width: 1, height: 1)))
                        var rgba = [UInt8](repeating: 0, count: 4)
                        rgba.withUnsafeMutableBytes { buffer in
                            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)!
                            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                        }
                        #expect(rgba[0] < 80 && rgba[1] < 80 && rgba[2] < 80 && rgba[3] == 255,
                                "尾部应显示媒体内容，而不是白色背景：\(probe), \(rgba)")
                    }
                    Attachment.record(image, named: "bubble-\(isVideo ? "video" : "photo")-\(direction)-\(rtl ? "rtl" : "ltr")-\(Int(size.height)).png")
                }
            }
        }
    }

    /// 复用同一张卡片时，实况标志不能泄漏到普通照片、GIF 或视频。
    @Test func messageLivePhotoBadgeFollowsIdentityAndReuse() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 4, videoIndices: [3], animatedIndices: [2], liveIndices: [0])
        defer { fixture.remove() }
        let view = makeStackView(fixture.group)
        for front in [0, 1, 2, 3, 0] {
            view.configure(messageID: 8, direction: .outgoing, group: fixture.group,
                           frontIndex: front, strings: mediaStrings)
            view.layoutIfNeeded()
            for card in view.cards where !card.isHidden {
                #expect(card.livePhotoBadge.isHidden == (card.mediaIndex != 0))
                #expect(!card.livePhotoBadge.isUserInteractionEnabled)
                #expect(!card.livePhotoBadge.isAccessibilityElement)
            }
        }
        // 消息单元格复用为另一条普通照片消息。
        let plain = MediaGroupAttachment(items: [fixture.group.items[1]])
        view.configure(messageID: 9, direction: .incoming, group: plain, frontIndex: 0, strings: mediaStrings)
        view.layoutIfNeeded()
        #expect(view.cards.allSatisfy { $0.livePhotoBadge.isHidden })
    }

    /// 单张气泡避开尾部，照片组沿每张卡片布局；RTL 镜像位置且不改变命中区域。
    @Test func messageLivePhotoBadgeGeometry() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 2, liveIndices: [0, 1])
        defer { fixture.remove() }
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        for count in [1, 2] {
            for direction in [MessageDirection.incoming, .outgoing] {
                for semantic in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
                    let group = MediaGroupAttachment(items: Array(fixture.group.items.prefix(count)))
                    let view = makeStackView(group, direction: direction)
                    view.semanticContentAttribute = semantic
                    window.rootViewController!.view.addSubview(view)
                    view.setNeedsLayout()
                    view.layoutIfNeeded()
                    for card in view.cards where !card.isHidden {
                        card.layoutIfNeeded()
                        let badge = card.livePhotoBadge
                        #expect(!badge.isHidden)
                        #expect(badge.bounds.size == CGSize(width: 18, height: 18))
                        #expect(abs(badge.frame.minY - 12) < 0.5)
                        let leading = semantic == .forceRightToLeft
                            ? card.bounds.width - badge.frame.maxX : badge.frame.minX
                        let expected: CGFloat = count == 1 && direction == .incoming ? 25 : 12
                        #expect(abs(leading - expected) < 0.5)
                        #expect(card.bounds.contains(badge.frame))
                        #expect(card.hitTest(badge.center, with: nil) !== badge)
                    }
                    view.removeFromSuperview()
                }
            }
        }
    }

    /// 同一草稿身份从实况切换到 GIF、静态图、视频或导入占位时，不得残留实况角标。
    @Test(arguments: [false, true])
    func draftLivePhotoBadgeClearsAcrossContentChanges(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 4, videoIndices: [3], animatedIndices: [1], liveIndices: [0])
        defer { fixture.remove() }
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        strip.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        let id = UUID()
        func apply(_ content: MediaDraftItemContent) async throws {
            strip.configure(.init(groupID: fixture.group.id, items: [.init(id: id, assetIdentifier: nil, content: content)]),
                            strings: mediaStrings, animated: false)
            for _ in 0..<20 where strip.isUpdatingPresentation {
                strip.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            strip.layoutIfNeeded()
            #expect(!strip.isUpdatingPresentation)
        }
        func badge(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "imessage.composer.media.livePhotoBadge" { return view }
            return view.subviews.lazy.compactMap { badge(in: $0) }.first
        }
        try await apply(.ready(fixture.group.items[0]))
        let liveCard = try #require(strip.previewSource(id: id))
        liveCard.layoutIfNeeded()
        let liveBadge = try #require(badge(in: liveCard))
        #expect(!liveBadge.isHidden)
        #expect(strip.livePhotoBadgeItemIDs == [id])
        let frame = liveBadge.convert(liveBadge.bounds, to: liveCard)
        #expect(liveCard.bounds.contains(frame))
        #expect(rtl ? frame.midX > liveCard.bounds.midX : frame.midX < liveCard.bounds.midX)

        for index in [1, 2, 3] {
            try await apply(.ready(fixture.group.items[index]))
            let card = try #require(strip.previewSource(id: id))
            card.layoutIfNeeded()
            #expect(strip.livePhotoBadgeItemIDs.isEmpty)
            #expect(liveBadge.isHidden || !liveBadge.isDescendant(of: card))
            #expect(badge(in: card).map(\.isHidden) ?? true)
            if index == 1 { #expect(card.accessibilityLabel?.contains(mediaStrings.animatedImage) == true) }
            if index == 2 { #expect(card.accessibilityLabel?.contains(mediaStrings.image) == true) }
        }
        try await apply(.ready(fixture.group.items[0]))
        let restoredCard = try #require(strip.previewSource(id: id))
        restoredCard.layoutIfNeeded()
        let restoredBadge = try #require(badge(in: restoredCard))
        #expect(!restoredBadge.isHidden)
        try await apply(.importing)
        #expect(strip.previewSource(id: id) == nil)
        #expect(strip.livePhotoBadgeItemIDs.isEmpty)
        #expect(restoredBadge.isHidden || !restoredBadge.isDescendant(of: strip))
    }

    @Test func draftVideoDurationKeepsContrastBackgroundWithQuickLayout() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1, videoIndices: [0])
        defer { fixture.remove() }
        let item = fixture.group.items[0]
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: [.init(id: item.id, assetIdentifier: nil, content: .ready(item))]), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        let card = try #require(strip.previewSource(id: item.id))
        card.layoutIfNeeded()
        let background = try #require(card.subviews.first(where: { $0.layer.cornerRadius == 5 }))
        let label = try #require(background.subviews.compactMap { $0 as? UILabel }.first)
        #expect(background.backgroundColor == UIColor.black.withAlphaComponent(0.65))
        #expect(background.bounds.width == label.bounds.width + 8)
        #expect(background.bounds.height == label.bounds.height + 4)
        #expect(background.bounds.contains(label.frame))
    }

    /// 首张、批量追加、重新选择都使用稳定身份；更新完成后仅最新选择留在快照中。
    @Test func draftCollectionCoalescesImportDeleteAndReorder() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3)
        defer { fixture.remove() }
        let items = fixture.group.items.map { MediaDraftItemPresentation(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .ready($0)) }
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: [items[0]]), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        let source = try #require(strip.previewSource(id: items[0].id))
        let remove = try #require(source.subviews.compactMap { $0 as? DraftRemoveButton }.first)
        var removed: [UUID] = []
        strip.removeRequested = { removed.append($0) }
        strip.configure(.init(groupID: fixture.group.id, items: items), strings: mediaStrings)
        strip.configure(.init(groupID: fixture.group.id, items: [items[2], items[1]]), strings: mediaStrings)
        remove.sendActions(for: .touchUpInside)
        #expect(removed.isEmpty)
        #expect(strip.previewSource(id: items[0].id) == nil)
        try await settleDraft(strip, ids: [items[2].id, items[1].id])
        #expect(strip.renderedItemFrames.count == 2)
        #expect(strip.previewSource(id: items[0].id) == nil)
        strip.configure(nil, strings: mediaStrings)
        try await settleDraft(strip, ids: [])
        #expect(strip.renderedItemFrames.isEmpty)
    }

    @Test func draftReadyUpdateKeepsCellAndVisibleAnchor() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 6, pixelSizes: Array(repeating: CGSize(width: 1600, height: 900), count: 6))
        defer { fixture.remove() }
        var items = fixture.group.items.map { MediaDraftItemPresentation(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .importing) }
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: items), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        strip.collectionView.setContentOffset(CGPoint(x: 172, y: 0), animated: false)
        strip.collectionView.layoutIfNeeded()
        let cell = try #require(strip.collectionView.cellForItem(at: IndexPath(item: 2, section: 0)))
        let screenX = strip.renderedItemFrames[2].minX - strip.collectionView.contentOffset.x
        items[0] = .init(id: items[0].id, assetIdentifier: items[0].assetIdentifier, content: .ready(fixture.group.items[0]))
        items[2] = .init(id: items[2].id, assetIdentifier: items[2].assetIdentifier, content: .ready(fixture.group.items[2]))
        strip.configure(.init(groupID: fixture.group.id, items: items), strings: mediaStrings)
        try await Task.sleep(nanoseconds: 40_000_000)
        let intermediateWidth = try #require(cell.layer.presentation()).bounds.width
        #expect(intermediateWidth > 80 && intermediateWidth < 208)
        try await settleDraft(strip, ids: items.map(\.id))
        #expect(strip.collectionView.cellForItem(at: IndexPath(item: 2, section: 0)) === cell)
        #expect(abs(strip.renderedItemFrames[2].minX - strip.collectionView.contentOffset.x - screenX) < 1)
        #expect(strip.renderedItemFrames[2].width == 208)
        #expect(strip.previewSource(id: items[2].id) != nil)
        #expect(strip.previewSource(id: items[0].id) == nil)
    }

    @Test(arguments: [false, true])
    func draftAppendAlwaysRevealsNewestItemAndMirrorsRTL(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 6)
        defer { fixture.remove() }
        let items = fixture.group.items.map { MediaDraftItemPresentation(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .ready($0)) }
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        strip.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: Array(items.prefix(5))), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        let startX = rtl ? strip.collectionView.contentSize.width - 238 : -2
        strip.collectionView.setContentOffset(CGPoint(x: startX, y: 0), animated: false)
        strip.configure(.init(groupID: fixture.group.id, items: items), strings: mediaStrings)
        // 插入还在动画时，布局事务就必须包含完整显示最后新增项的目标几何，
        // 不得等插入 completion 后才另起一段自动滚动。
        try await Task.sleep(nanoseconds: 40_000_000)
        let insertedFrame = try #require(strip.renderedItemFrames.last)
        #expect(strip.collectionView.bounds.insetBy(dx: -0.5, dy: 0).contains(insertedFrame))
        try await settleDraft(strip, ids: items.map(\.id))
        let frames = strip.renderedItemFrames
        #expect(rtl ? frames[0].minX > frames[1].minX : frames[0].minX < frames[1].minX)
        let last = try #require(frames.last)
        #expect(strip.collectionView.bounds.insetBy(dx: -0.5, dy: 0).contains(last))
        #expect(strip.previewSource(id: items.last!.id) != nil)
        #expect(strip.previewSource(id: items[0].id) == nil)
    }

    @Test(arguments: [false, true])
    func draftImportedLastItemKeepsItsTrailingEdgeVisible(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3, pixelSizes: Array(repeating: CGSize(width: 1600, height: 900), count: 3))
        defer { fixture.remove() }
        var items = fixture.group.items.map { MediaDraftItemPresentation(id: $0.id, assetIdentifier: nil, content: .importing) }
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        strip.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: items), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        for index in [2, 0, 1] {
            items[index] = .init(id: items[index].id, assetIdentifier: nil, content: .ready(fixture.group.items[index]))
            strip.configure(.init(groupID: fixture.group.id, items: items), strings: mediaStrings)
            try await settleDraft(strip, ids: items.map(\.id))
            let last = try #require(strip.renderedItemFrames.last)
            #expect(strip.collectionView.bounds.insetBy(dx: -0.5, dy: 0).contains(last))
        }
    }

    @Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)], [false, true])
    func draftMediaUsesSelectedAspectRatioBeforeImport(size: CGSize, isVideo: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1, videoIndices: isVideo ? [0] : [], pixelSizes: [size])
        defer { fixture.remove() }
        let item = fixture.group.items[0]
        let entry = PhotoPickerController.DraftEntry(id: item.id, assetIdentifier: nil,
                                                    initialDisplaySize: size, waitsForDisplaySize: true)
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: [entry.presentation]), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        let before = try #require(strip.renderedItemFrames.first)
        #expect(before.size == MediaDraftItemSizing.size(for: size))
        #expect(entry.presentation.mediaItem == nil)
        entry.content = .ready(item)
        strip.configure(.init(groupID: fixture.group.id, items: [entry.presentation]), strings: mediaStrings)
        try await settleDraft(strip, ids: [item.id])
        #expect(strip.renderedItemFrames.first == before)
    }

    @Test func draftVideoWithUnknownInitialSizeSettlesGeometryBeforeShowingImage() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1, videoIndices: [0], pixelSizes: [CGSize(width: 1920, height: 1080)])
        defer { fixture.remove() }
        let item = fixture.group.items[0]
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: [.init(id: item.id, assetIdentifier: nil, content: .importing)]), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        #expect(strip.renderedItemFrames.first?.width == 80)
        strip.configure(.init(groupID: fixture.group.id, items: [.init(id: item.id, assetIdentifier: nil, content: .ready(item))]), strings: mediaStrings)
        try await Task.sleep(nanoseconds: 40_000_000)
        let cell = try #require(strip.collectionView.cellForItem(at: .init(item: 0, section: 0)))
        #expect(cell.bounds.width == 208)
        #expect(cell.layer.presentation()?.bounds.width == 208)
        try await settleDraft(strip, ids: [item.id])
        #expect(strip.previewSource(id: item.id) != nil)
        #expect(PhotoPickerController.validDisplaySize(.zero) == nil)
        #expect(PhotoPickerController.validDisplaySize(CGSize(width: CGFloat.infinity, height: 100)) == nil)
    }

    @Test(arguments: [false, true])
    func unknownMediaWaitsForMetadataWithoutLosingBusinessState(isVideo: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1, videoIndices: isVideo ? [0] : [], pixelSizes: [CGSize(width: 1920, height: 1080)])
        defer { fixture.remove() }
        let item = fixture.group.items[0]
        let entry = PhotoPickerController.DraftEntry(id: item.id, assetIdentifier: nil, waitsForDisplaySize: true)
        let composer = ComposerView(frame: CGRect(x: 0, y: 100, width: 320, height: 60))
        composer.configure(strings: ConversationPreviewData.composerStrings, mediaStrings: mediaStrings)
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(composer)
        let emptyHeight = composer.intrinsicContentSize.height
        composer.applyMediaDraft(.init(groupID: fixture.group.id, items: [entry.presentation]), animated: false)
        composer.layoutIfNeeded()
        #expect(composer.mediaDraft?.items.count == 1)
        #expect(composer.mediaDraft?.canSend == false)
        #expect(!composer.hasVisibleMediaDraft)
        #expect(composer.intrinsicContentSize.height == emptyHeight)
        #expect(composer.mediaDraftStripView.renderedItemIDs.isEmpty)
        entry.content = .ready(item)
        composer.applyMediaDraft(.init(groupID: fixture.group.id, items: [entry.presentation]))
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.setNeedsQuickLayout()
        composer.layoutIfNeeded()
        try await settleDraft(composer.mediaDraftStripView, ids: [item.id])
        #expect(composer.hasVisibleMediaDraft)
        #expect(composer.mediaDraft?.canSend == true)
        #expect(composer.mediaDraftStripView.renderedItemFrames.first?.size == CGSize(width: 208, height: 156))
        composer.applyMediaDraft(nil, animated: false)
        #expect(composer.mediaDraft == nil)
        #expect(composer.intrinsicContentSize.height == emptyHeight)
    }

    @Test(arguments: [false, true])
    func delayedEarlierVideoKeepsLastSelectedPhotoVisible(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3, videoIndices: [0], pixelSizes: Array(repeating: CGSize(width: 1920, height: 1080), count: 3))
        defer { fixture.remove() }
        let video = fixture.group.items[0]
        let entry = PhotoPickerController.DraftEntry(id: video.id, assetIdentifier: nil, waitsForDisplaySize: true)
        let photos = fixture.group.items.dropFirst().map { MediaDraftItemPresentation(id: $0.id, assetIdentifier: nil, content: .ready($0)) }
        let strip = MediaDraftStripView(frame: CGRect(x: 0, y: 100, width: 240, height: 156))
        strip.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(strip)
        strip.configure(.init(groupID: fixture.group.id, items: [entry.presentation] + photos), strings: mediaStrings, animated: false)
        strip.layoutIfNeeded()
        entry.content = .ready(video)
        strip.configure(.init(groupID: fixture.group.id, items: [entry.presentation] + photos), strings: mediaStrings)
        try await settleDraft(strip, ids: fixture.group.items.map(\.id))
        #expect(strip.collectionView.bounds.contains(try #require(strip.renderedItemFrames.last)))
    }

    @Test(arguments: [false, true])
    func firstDraftRevealsAboveEditorWithoutStretchingCard(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1, videoIndices: [0], pixelSizes: [CGSize(width: 1920, height: 1080)])
        defer { fixture.remove() }
        let item = fixture.group.items[0]
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        composer.configure(strings: ConversationPreviewData.composerStrings, mediaStrings: mediaStrings)
        composer.applyLayoutDirection(rtl ? .rightToLeft : .leftToRight)
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(composer)
        composer.frame = CGRect(x: 0, y: 500 - composer.intrinsicContentSize.height,
                                width: 320, height: composer.intrinsicContentSize.height)
        composer.layoutIfNeeded()
        let microphoneRect = composer.dictationButton.convert(composer.dictationButton.bounds, to: window)
        let initialEditorRect = composer.editorContainer.convert(composer.editorContainer.bounds, to: window)
        #expect(abs(microphoneRect.midY - initialEditorRect.midY) < 0.5)
        var animator: UIViewPropertyAnimator?
        composer.heightDidChange = { _ in
            // 与页面一样保持输入栏底边，以一份父级动画驱动整个展开。
            animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 1) {
                composer.frame = CGRect(x: 0, y: 500 - composer.intrinsicContentSize.height,
                                        width: 320, height: composer.intrinsicContentSize.height)
                composer.layoutIfNeeded()
            }
            animator?.startAnimation()
        }
        composer.applyMediaDraft(.init(groupID: fixture.group.id, items: [
            .init(id: item.id, assetIdentifier: nil, content: .ready(item))
        ]))
        try await Task.sleep(nanoseconds: 80_000_000)
        let strip = composer.mediaDraftStripView
        let viewport = try #require(strip.layer.presentation())
        let editor = try #require(composer.editorContainer.layer.presentation())
        let viewportRect = viewport.convert(viewport.bounds, to: nil)
        let editorRect = editor.convert(editor.bounds, to: nil)
        // 淡出的麦克风仍须留在底部；只检查最终 frame 无法发现随玻璃上移的问题。
        let microphone = try #require(composer.dictationButton.layer.presentation())
        let microphoneDuringExpansion = microphone.convert(microphone.bounds, to: nil)
        #expect(abs(microphoneDuringExpansion.midY - microphoneRect.midY) < 1)
        let send = try #require(composer.sendButton.layer.presentation())
        let sendDuringExpansion = send.convert(send.bounds, to: nil)
        #expect(abs(sendDuringExpansion.midY - initialEditorRect.midY) < 1)
        #expect(strip.clipsToBounds)
        #expect(viewportRect.maxY <= editorRect.minY + 1)
        #expect(strip.collectionView.bounds.height == MediaDraftAppearance.itemHeight)
        #expect(strip.renderedItemFrames.first?.size == CGSize(width: 208, height: 156))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(strip.bounds.height == MediaDraftAppearance.itemHeight)
        #expect(strip.collectionView.frame.minY == 0)
        #expect(strip.collectionView.bounds.contains(try #require(strip.renderedItemFrames.last)))
        let sendRect = composer.sendButton.convert(composer.sendButton.bounds, to: window)
        composer.applyMediaDraft(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        let outgoingSend = try #require(composer.sendButton.layer.presentation())
        #expect(abs(outgoingSend.convert(outgoingSend.bounds, to: nil).midY - sendRect.midY) < 1)
        let returningMicrophone = try #require(composer.dictationButton.layer.presentation())
        #expect(abs(returningMicrophone.convert(returningMicrophone.bounds, to: nil).midY - microphoneRect.midY) < 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        animator?.stopAnimation(true)
    }

    @Test func draftCollapsePublishesStateImmediatelyAndCleansInterruptedSnapshot() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1)
        defer { fixture.remove() }
        let item = fixture.group.items[0]
        let draft = MediaDraftPresentation(groupID: fixture.group.id, items: [.init(id: item.id, assetIdentifier: nil, content: .ready(item))])
        let composer = ComposerView(frame: CGRect(x: 0, y: 100, width: 320, height: 220))
        let window = try makeDraftTestWindow()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(composer)
        var transitions: [ComposerView.HeightChange] = []
        composer.heightDidChange = { transitions.append($0) }
        composer.applyMediaDraft(draft, animated: false)
        composer.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 80_000_000)
        composer.applyMediaDraft(nil)
        #expect(composer.mediaDraft == nil)
        #expect(!composer.hasSendableContent)
        let departing = composer.mediaDraftExitSnapshot
        #expect(departing != nil)
        composer.applyMediaDraft(draft)
        #expect(departing?.superview == nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(composer.mediaDraft == draft)
        #expect(composer.mediaDraftExitSnapshot == nil)
        #expect(transitions.count == 3)
        if case .immediate = transitions[0] {} else { Issue.record("Initial restoration must not animate") }
        if case .mediaDraft = transitions[1] {} else { Issue.record("Visible collapse should animate") }
    }

    private func makeDraftTestWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    /// 有界等待 collection 更新与最后一次自动滚动结束，不用长时间压力循环。
    private func settleDraft(_ strip: MediaDraftStripView, ids: [UUID]) async throws {
        for _ in 0..<60 {
            strip.layoutIfNeeded()
            if strip.renderedItemIDs == ids && !strip.isUpdatingPresentation { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        Issue.record("Draft did not settle to the latest snapshot")
    }

    @Test func mediaGroupAndFollowupTextPublishAtomically() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5, videoIndices: [2])
        defer { fixture.remove() }
        let viewModel = makeViewModel()
        var reasons: [ChatViewModel.UpdateReason] = []
        viewModel.bind { _, reason in reasons.append(reason) }

        #expect(
            viewModel.sendMediaGroup(
                fixture.group,
                followedByText: "  caption  "
            )
        )

        let messages = messagePresentations(in: viewModel.state)
        let media = try #require(messages.first(where: { $0.id == 0 }))
        let text = try #require(messages.first(where: { $0.id == 1 }))
        #expect(media.mediaGroup == fixture.group)
        #expect(media.deliveryText == "localized.imessage.status.sending")
        #expect(text.text == "  caption  ")
        #expect(text.deliveryText == "localized.imessage.status.sending")
        #expect(!viewModel.state.isTyping)
        #expect(viewModel.state.isProcessingMessages)
        #expect(reasons == [.initial, .sentMessage])
        viewModel.cancelPendingReply()
    }

    @Test func mediaGroupWithoutTextOwnsDeliveryStatus() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1)
        defer { fixture.remove() }
        let viewModel = makeViewModel()

        #expect(
            viewModel.sendMediaGroup(
                fixture.group,
                followedByText: " \n "
            )
        )

        let sent = try #require(
            messagePresentations(in: viewModel.state)
                .first(where: { $0.id == 0 })
        )
        #expect(sent.mediaGroup == fixture.group)
        #expect(sent.deliveryText == "localized.imessage.status.sending")
        #expect(!messagePresentations(in: viewModel.state).contains { $0.id == 1 })
        viewModel.cancelPendingReply()
    }

    @Test func twentyMediaItemsRemainOneOrderedMessage() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 20, videoIndices: [3, 19])
        defer { fixture.remove() }
        let viewModel = makeViewModel()

        #expect(viewModel.sendMediaGroup(fixture.group, followedByText: ""))
        let sent = try #require(
            messagePresentations(in: viewModel.state)
                .first(where: { $0.id == 0 })
        )
        #expect(sent.mediaGroup?.items.count == 20)
        #expect(sent.mediaGroup?.items.map(\.id) == fixture.group.items.map(\.id))
        viewModel.cancelPendingReply()
    }

    @Test func mediaValidationRejectsInvalidGroupsWithoutPartialMessages() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1)
        defer { fixture.remove() }
        let viewModel = makeViewModel()
        let originalTimeline = viewModel.state.timeline

        #expect(
            !viewModel.sendMediaGroup(
                MediaGroupAttachment(items: []),
                followedByText: "must remain"
            )
        )
        let tooMany = MediaGroupAttachment(
            items: Array(repeating: fixture.group.items[0], count: 21)
        )
        #expect(!viewModel.sendMediaGroup(tooMany, followedByText: "must remain"))

        let missingItem = MediaItem(
            assetIdentifier: nil,
            originalFileURL: fixture.directory.appendingPathComponent("missing.jpg"),
            thumbnailFileURL: fixture.group.items[0].thumbnailFileURL,
            pixelSize: CGSize(width: 100, height: 100),
            kind: .image
        )
        #expect(
            !viewModel.sendMediaGroup(
                MediaGroupAttachment(items: [missingItem]),
                followedByText: "must remain"
            )
        )
        let invalidVideo = MediaItem(
            assetIdentifier: nil,
            originalFileURL: fixture.group.items[0].originalFileURL,
            thumbnailFileURL: fixture.group.items[0].thumbnailFileURL,
            pixelSize: CGSize(width: 100, height: 100),
            kind: .video(duration: 0)
        )
        #expect(
            !viewModel.sendMediaGroup(
                MediaGroupAttachment(items: [invalidVideo]),
                followedByText: "must remain"
            )
        )
        #expect(viewModel.state.timeline == originalTimeline)
    }

    @Test func mediaDraftRequiresEveryOrderedImportToFinish() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 2, videoIndices: [1])
        defer { fixture.remove() }
        let ready = fixture.group.items.map {
            MediaDraftItemPresentation(
                id: $0.id,
                assetIdentifier: $0.assetIdentifier,
                content: .ready($0)
            )
        }
        let importing = MediaDraftPresentation(
            groupID: fixture.group.id,
            items: [
                ready[0],
                MediaDraftItemPresentation(
                    id: ready[1].id,
                    assetIdentifier: ready[1].assetIdentifier,
                    content: .importing
                ),
            ]
        )
        #expect(!importing.canSend)
        #expect(importing.attachment == nil)

        let complete = MediaDraftPresentation(
            groupID: fixture.group.id,
            items: ready
        )
        #expect(complete.canSend)
        #expect(complete.attachment?.items.map(\.id) == fixture.group.items.map(\.id))
    }

    /// 导入中与追加媒体时保持发送入口，只有全部就绪才可发送，清空后恢复听写。
    @Test(arguments: [false, true])
    func composerKeepsSendButtonThroughoutMediaImport(hasExistingText: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 2)
        defer { fixture.remove() }
        let host = UIViewController()
        let window = try makeVisibleTestWindow(rootViewController: host)
        defer { window.isHidden = true }
        let composer = ComposerView(frame: CGRect(x: 0, y: 100, width: 402, height: 60))
        host.view.addSubview(composer)
        if hasExistingText {
            composer.textView.text = "Caption"
            composer.textViewDidChange(composer.textView)
        }
        var actions: [ComposerAction] = []
        composer.actionRequested = { actions.append($0); return false }
        let ready = fixture.group.items.map {
            MediaDraftItemPresentation(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .ready($0))
        }
        let importing = ready.map {
            MediaDraftItemPresentation(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .importing)
        }
        func visible(_ view: UIView) -> Bool {
            guard view.window != nil else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha == 0 { return false }
                ancestor = current.superview
            }
            return true
        }
        func check(_ items: [MediaDraftItemPresentation], canSend: Bool) {
            composer.applyMediaDraft(items.isEmpty ? nil : .init(groupID: fixture.group.id, items: items))
            composer.frame.size.height = composer.intrinsicContentSize.height
            composer.layoutIfNeeded()
            let showsSend = !items.isEmpty || !composer.textView.text.isEmpty
            #expect(visible(composer.sendButton) == showsSend)
            #expect(visible(composer.dictationButton) == !showsSend)
            #expect(composer.sendButton.isEnabled)
            #expect(composer.sendButton.tintColor == .systemBlue)
            #expect(composer.sendButton.isUserInteractionEnabled == canSend)
            #expect(composer.sendButton.accessibilityTraits.contains(.notEnabled) == !canSend)
            #expect(!composer.textView.isFirstResponder)
        }
        check([], canSend: hasExistingText)
        check([importing[0]], canSend: false)
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(actions.isEmpty)
        check([ready[0]], canSend: true)
        check([ready[0], importing[1]], canSend: false)
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(actions.isEmpty)
        check(ready, canSend: true)
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(actions.count == 1)
        check([ready[0]], canSend: true)
        composer.textView.text = nil
        composer.textViewDidChange(composer.textView)
        check([], canSend: false)
    }

    @Test func mediaDraftItemWidthFollowsAttachmentAspectRatioWithinLimits() {
        guard #available(iOS 26.0, *) else { return }
        #expect(
            MediaDraftItemSizing.size(
                for: CGSize(width: 900, height: 1600)
            ) == CGSize(width: 87.75, height: 156)
        )
        #expect(
            MediaDraftItemSizing.size(
                for: CGSize(width: 1000, height: 1000)
            ) == CGSize(width: 156, height: 156)
        )
        #expect(
            MediaDraftItemSizing.size(
                for: CGSize(width: 1600, height: 900)
            ) == CGSize(width: 208, height: 156)
        )
        #expect(
            MediaDraftItemSizing.size(for: .zero)
                == CGSize(width: 80, height: 156)
        )
    }

    @Test func composerRendersScaledDraftItemsLivePhotoBadgeAndHairline() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(
            itemCount: 3,
            pixelSizes: [
                CGSize(width: 900, height: 1600),
                CGSize(width: 1000, height: 1000),
                CGSize(width: 1600, height: 900),
            ],
            animatedIndices: [1],
            liveIndices: [2]
        )
        defer { fixture.remove() }
        let draft = MediaDraftPresentation(
            groupID: fixture.group.id,
            items: fixture.group.items.map {
                MediaDraftItemPresentation(
                    id: $0.id,
                    assetIdentifier: $0.assetIdentifier,
                    content: .ready($0)
                )
            }
        )
        let composer = ComposerView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 60)
        )
        composer.configure(
            strings: ConversationPreviewData.composerStrings,
            mediaStrings: mediaStrings
        )
        composer.applyMediaDraft(draft)
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.setNeedsQuickLayout()
        composer.layoutIfNeeded()

        let itemFrames = composer.mediaDraftStripView.renderedItemFrames
        #expect(itemFrames.map(\.size) == [
            CGSize(width: 87.75, height: 156),
            CGSize(width: 156, height: 156),
            CGSize(width: 208, height: 156),
        ])
        #expect(itemFrames[1].minX - itemFrames[0].maxX == 6)
        #expect(itemFrames[2].minX - itemFrames[1].maxX == 6)
        #expect(
            composer.mediaDraftStripView.livePhotoBadgeItemIDs
                == [fixture.group.items[2].id]
        )

        let stripFrame = composer.mediaDraftStripView.convert(
            composer.mediaDraftStripView.bounds,
            to: composer
        )
        let separatorFrame = composer.mediaDraftSeparatorView.convert(
            composer.mediaDraftSeparatorView.bounds,
            to: composer
        )
        let textFrame = composer.textView.convert(
            composer.textView.bounds,
            to: composer
        )
        #expect(
            abs(
                separatorFrame.height
                    - 1 / max(1, composer.traitCollection.displayScale)
            ) < 0.01
        )
        #expect(separatorFrame.minY >= stripFrame.maxY + 3.9)
        #expect(separatorFrame.maxY < textFrame.minY)
        #expect(abs(separatorFrame.minX - 84) < 0.5)
        #expect(abs(separatorFrame.maxX - 370) < 0.5)
        #expect(composer.placeholderLabel.text == "添加注释或发送")
        composer.applyMediaDraft(nil)
        #expect(composer.placeholderLabel.text == ConversationPreviewData.composerStrings.placeholder)
        #expect(composer.textView.accessibilityLabel == ConversationPreviewData.composerStrings.placeholder)
    }

    @Test func fiveItemRenderOrderRotatesWithoutMutatingModelOrder() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        let originalIDs = fixture.group.items.map(\.id)
        #expect(MediaStackPolicy.renderOrder(frontIndex: 0, itemCount: 5) == [0, 1, 2, 3, 4])
        #expect(MediaStackPolicy.renderOrder(frontIndex: 1, itemCount: 5) == [1, 2, 3, 4, 0])
        #expect(MediaStackPolicy.renderOrder(frontIndex: 2, itemCount: 5) == [2, 3, 4, 0, 1])
        #expect(MediaStackPolicy.renderOrder(frontIndex: 3, itemCount: 5) == [3, 4, 0, 1, 2])
        #expect(MediaStackPolicy.renderOrder(frontIndex: 4, itemCount: 5) == [4, 0, 1, 2, 3])
        #expect(fixture.group.items.map(\.id) == originalIDs)
    }

    @Test func fiveItemStackDistributesCardsAcrossTheCurrentCover() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        let view = MediaMessageView()

        func configure(frontIndex: Int) {
            view.configure(
                messageID: 7,
                direction: .outgoing,
                group: fixture.group,
                frontIndex: frontIndex,
                strings: mediaStrings
            )
            view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }

        #expect(MediaStackPolicy.visibleIndices(frontIndex: 0, itemCount: 5) == [0, 1, 2, 3, 4])
        #expect(MediaStackPolicy.visibleIndices(frontIndex: 2, itemCount: 5) == [0, 1, 2, 3, 4])
        #expect(MediaStackPolicy.visibleIndices(frontIndex: 4, itemCount: 5) == [0, 1, 2, 3, 4])
        #expect(
            MediaStackPolicy.visibleIndices(
                frontIndex: 10,
                itemCount: 20
            ) == [8, 9, 10, 11, 12]
        )
        #expect(
            MediaStackPolicy.visibleIndices(
                frontIndex: 19,
                itemCount: 20
            ) == [15, 16, 17, 18, 19]
        )

        configure(frontIndex: 0)
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minX == 0)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minX == 32)
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minY == 32)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minY == 56)

        configure(frontIndex: 2)
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minX == 0)
        #expect(view.visibleCardFrame(forMediaIndex: 2)?.minX == 16)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minX == 32)
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minY == 44)
        #expect(view.visibleCardFrame(forMediaIndex: 2)?.minY == 32)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minY == 44)
        #expect(view.visibleCardZPosition(forMediaIndex: 2) == 30)
        #expect(view.visibleCardZPosition(forMediaIndex: 1) == 29)
        #expect(view.visibleCardZPosition(forMediaIndex: 0) == 28)
        let previousAngle = view.visibleCardRestingTransform(forMediaIndex: 0)
            .map { atan2($0.b, $0.a) } ?? 0
        let nextAngle = view.visibleCardRestingTransform(forMediaIndex: 4)
            .map { atan2($0.b, $0.a) } ?? 0
        #expect(previousAngle > 0)
        #expect(nextAngle < 0)

        configure(frontIndex: 4)
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minX == 0)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minX == 32)
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minY == 56)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minY == 32)

        view.semanticContentAttribute = .forceRightToLeft
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.visibleCardFrame(forMediaIndex: 0)?.minX == 32)
        #expect(view.visibleCardFrame(forMediaIndex: 4)?.minX == 0)
        let mirroredPreviousAngle = view.visibleCardRestingTransform(forMediaIndex: 0)
            .map { atan2($0.b, $0.a) } ?? 0
        #expect(mirroredPreviousAngle < 0)
    }

    @Test func twentyItemStackCapsVisibleLayersAtFiveAndReusesStableCards() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 20)
        defer { fixture.remove() }
        let view = MediaMessageView()

        view.configure(
            messageID: 8,
            direction: .outgoing,
            group: fixture.group,
            frontIndex: 2,
            strings: mediaStrings
        )
        view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutIfNeeded()
        let stableCardIDs = Dictionary(
            uniqueKeysWithValues: (1...4).compactMap { index in
                view.visibleCardObjectIdentifier(forMediaIndex: index).map {
                    (index, $0)
                }
            }
        )

        #expect(view.visibleCardCount == 5)
        #expect(view.intrinsicContentSize == CGSize(width: 248, height: 364))

        view.configure(
            messageID: 8,
            direction: .outgoing,
            group: fixture.group,
            frontIndex: 3,
            strings: mediaStrings
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(view.visibleCardCount == 5)
        for index in 1...4 {
            #expect(
                view.visibleCardObjectIdentifier(forMediaIndex: index)
                    == stableCardIDs[index]
            )
        }
        #expect(view.visibleCardFrame(forMediaIndex: 1)?.minX == 0)
        #expect(view.visibleCardFrame(forMediaIndex: 3)?.minX == 16)
        #expect(view.visibleCardFrame(forMediaIndex: 5)?.minX == 32)
    }

    @Test func stackGesturePolicyUsesPhysicalDirectionsThresholdsAndBoundaries() {
        guard #available(iOS 26.0, *) else { return }
        #expect(MediaStackPolicy.isHorizontalPan(velocity: CGPoint(x: 121, y: 100)))
        #expect(!MediaStackPolicy.isHorizontalPan(velocity: CGPoint(x: 120, y: 100)))
        #expect(MediaStackPolicy.targetIndex(frontIndex: 2, itemCount: 5, translationX: -50, velocityX: 0) == 3)
        #expect(MediaStackPolicy.targetIndex(frontIndex: 2, itemCount: 5, translationX: 50, velocityX: 0) == 1)
        #expect(MediaStackPolicy.targetIndex(frontIndex: 0, itemCount: 5, translationX: 50, velocityX: 0) == nil)
        #expect(MediaStackPolicy.targetIndex(frontIndex: 4, itemCount: 5, translationX: -50, velocityX: 0) == nil)
        #expect(MediaStackPolicy.shouldCommit(translationX: 130, velocityX: 0, isReordered: true))
        #expect(!MediaStackPolicy.shouldCommit(translationX: 43, velocityX: 549, isReordered: false))
        #expect(MediaStackPolicy.shouldCommit(translationX: -2, velocityX: -550, isReordered: false))
        #expect(!MediaStackPolicy.shouldCommit(translationX: -2, velocityX: 700, isReordered: false))
    }

    /// 换层后略微回拖越过同一临界值即恢复，越过起点后重新计算另一侧候选。
    @Test func stackPreviewReordersReversiblyWithoutChangingItsStartIndex() {
        guard #available(iOS 26.0, *) else { return }
        var state = MediaStackPolicy.Interaction(startIndex: 2, itemCount: 5, cardWidth: 200)
        for (distance, reordered) in [(-119.0, false), (-120, true), (-119.9, false),
                                       (-120, true), (-119.9, false), (-112, false),
                                       (-108, false), (-107, false), (-150, true), (-80, false)] {
            state.update(translationX: distance)
            #expect(state.isReordered == reordered)
            #expect(state.startIndex == 2)
            #expect(state.candidateIndex == 3)
            #expect(state.committedIndex(velocityX: 0) == (reordered ? 3 : nil))
        }
        state.update(translationX: 40)
        #expect(state.candidateIndex == 1)
        #expect(!state.isReordered)
        state.update(translationX: 120)
        #expect(state.committedIndex(velocityX: 0) == 1)
        state.update(translationX: 0)
        #expect(state.candidateIndex == nil)
        #expect(!state.isReordered)
    }

    /// 左右两个方向均在同一距离恢复真实卡片层级，且松手取消不发布索引。
    @Test func stackRestoresLayerImmediatelyBelowTheReorderThreshold() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        for sign in [CGFloat(-1), CGFloat(1)] {
            let view = makeStackView(fixture.group, frontIndex: 2)
            let candidate = sign < 0 ? 3 : 1
            let width = try #require(view.visibleCardFrame(forMediaIndex: 2)?.width)
            let threshold = width * 0.60
            var changeCount = 0
            view.frontIndexDidChange = { _, _ in changeCount += 1 }
            view.handlePan(state: .began, translationX: 0, velocityX: sign * 100)
            for _ in 0..<3 {
                view.handlePan(state: .changed, translationX: sign * threshold, velocityX: 0)
                #expect(view.visibleCardZPosition(forMediaIndex: candidate)! > view.visibleCardZPosition(forMediaIndex: 2)!)
                view.handlePan(state: .changed, translationX: sign * (threshold - 0.1), velocityX: 0)
                #expect(view.visibleCardZPosition(forMediaIndex: 2)! > view.visibleCardZPosition(forMediaIndex: candidate)!)
                #expect(view.frontMediaIndex == 2)
                #expect(changeCount == 0)
            }
            view.handlePan(state: .ended, translationX: sign * (threshold - 0.1), velocityX: 0, animated: false)
            #expect(view.frontMediaIndex == 2)
            #expect(changeCount == 0)
        }
    }

    /// 阈值取自实际宽度，速度仅用于松手判定，边界不会被快速甩动穿透。
    @Test func stackReleaseUsesActualWidthVelocityAndCollectionBoundaries() {
        guard #available(iOS 26.0, *) else { return }
        for width in [120.0, 216.0] {
            var state = MediaStackPolicy.Interaction(startIndex: 0, itemCount: 2, cardWidth: width)
            state.update(translationX: -width * 0.61)
            #expect(state.isReordered)
            #expect(state.progress == 1)
            state.update(translationX: -width * 0.50)
            #expect(state.committedIndex(velocityX: 0) == nil)
            state.update(translationX: -2)
            #expect(!state.isReordered)
            #expect(state.committedIndex(velocityX: -550) == 1)
            #expect(state.committedIndex(velocityX: -549) == nil)
            #expect(state.committedIndex(velocityX: 700) == nil)
            state.update(translationX: 200)
            #expect(state.progress == 0)
            #expect(state.displayedTranslationX == 18)
            #expect(state.committedIndex(velocityX: 900) == nil)
        }
        var last = MediaStackPolicy.Interaction(startIndex: 19, itemCount: 20, cardWidth: 216)
        last.update(translationX: -200)
        #expect(last.displayedTranslationX == -18)
        #expect(last.committedIndex(velocityX: -900) == nil)
    }

    /// 一次手势可多次换层，普通重新配置和布局不能提前提交或清除预览。
    @Test func stackDraggingPreservesIdentityAndCommitsOnlyAtRelease() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5, videoIndices: [0])
        defer { fixture.remove() }
        let view = makeStackView(fixture.group)
        let cardID = view.visibleCardObjectIdentifier(forMediaIndex: 0)
        let size = view.intrinsicContentSize
        var changes: [(Int, Int)] = []
        view.frontIndexDidChange = { changes.append(($0, $1)) }
        view.handlePan(state: .began, translationX: 0, velocityX: -100)
        view.handlePan(state: .changed, translationX: -140, velocityX: 0)
        #expect(view.frontMediaIndex == 0)
        #expect(changes.isEmpty)
        #expect(view.visibleCardZPosition(forMediaIndex: 1)! > view.visibleCardZPosition(forMediaIndex: 0)!)
        let transform = try #require(view.visibleCardTransform(forMediaIndex: 0))
        #expect(abs(hypot(transform.a, transform.b) - 0.72) < 0.001)
        let center = view.visibleCardCenter(forMediaIndex: 0)
        view.configure(messageID: 8, direction: .outgoing, group: fixture.group, frontIndex: 0, strings: mediaStrings)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.visibleCardTransform(forMediaIndex: 0) == transform)
        #expect(view.visibleCardCenter(forMediaIndex: 0) == center)
        #expect(view.visibleCardObjectIdentifier(forMediaIndex: 0) == cardID)
        #expect(view.mediaIndex(at: .zero) == nil)
        view.handlePan(state: .changed, translationX: -100, velocityX: 0)
        #expect(view.visibleCardZPosition(forMediaIndex: 0)! > view.visibleCardZPosition(forMediaIndex: 1)!)
        view.handlePan(state: .changed, translationX: -140, velocityX: 0)
        #expect(changes.isEmpty)
        view.handlePan(state: .ended, translationX: -140, velocityX: 0, animated: false)
        #expect(view.frontMediaIndex == 1)
        #expect(changes.count == 1)
        #expect(changes.first?.0 == 8 && changes.first?.1 == 1)
        #expect(view.visibleCardObjectIdentifier(forMediaIndex: 0) == cardID)
        #expect(view.intrinsicContentSize == size)
        #expect(view.visibleCardTransform(forMediaIndex: 0) == view.visibleCardRestingTransform(forMediaIndex: 0))
        #expect(view.visibleCardZPosition(forMediaIndex: 1) == 30)
    }

    /// 未过阈值、越界后回拖和系统取消均完整恢复所有卡片，而非只恢复原封面。
    @Test func stackCancellationRestoresEveryCard() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        for terminal in [UIGestureRecognizer.State.ended, .cancelled, .failed] {
            let view = makeStackView(fixture.group, frontIndex: 2)
            var changeCount = 0
            view.frontIndexDidChange = { _, _ in changeCount += 1 }
            let centers = (0..<5).map { view.visibleCardCenter(forMediaIndex: $0) }
            view.handlePan(state: .began, translationX: 0, velocityX: -100)
            view.handlePan(state: .changed, translationX: -150, velocityX: 0)
            if terminal == .ended {
                view.handlePan(state: .changed, translationX: -60, velocityX: 0)
            }
            view.handlePan(state: terminal, translationX: terminal == .ended ? -60 : -150,
                           velocityX: terminal == .ended ? 0 : -900, animated: false)
            #expect(view.frontMediaIndex == 2)
            #expect(changeCount == 0)
            for index in 0..<5 {
                #expect(view.visibleCardTransform(forMediaIndex: index) == view.visibleCardRestingTransform(forMediaIndex: index))
                #expect(view.visibleCardCenter(forMediaIndex: index) == centers[index])
                #expect(view.visibleCardZPosition(forMediaIndex: index) == CGFloat(30 - abs(index - 2)))
            }
        }
    }

    /// 大组窗口只在提交后移动；拖动中的方向、窄屏和边界复用共享同一逻辑。
    @Test func stackWindowAndGeometryChangesKeepConfirmedState() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 20)
        defer { fixture.remove() }
        for direction in [MessageDirection.incoming, .outgoing] {
            for semantic in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
                let view = makeStackView(fixture.group, frontIndex: 2, direction: direction)
                view.semanticContentAttribute = semantic
                view.frame.size.width = 180
                view.setNeedsLayout()
                view.layoutIfNeeded()
                let width = try #require(view.visibleCardFrame(forMediaIndex: 2)?.width)
                let stableIDs = (1...4).map { view.visibleCardObjectIdentifier(forMediaIndex: $0) }
                view.handlePan(state: .began, translationX: 0, velocityX: -100)
                view.handlePan(state: .changed, translationX: -width * 0.7, velocityX: 0)
                #expect(view.visibleCardCount == 5)
                #expect(view.visibleCardObjectIdentifier(forMediaIndex: 5) == nil)
                view.handlePan(state: .ended, translationX: -width * 0.7, velocityX: 0, animated: false)
                #expect(view.frontMediaIndex == 3)
                #expect(view.visibleCardCount == 5)
                for index in 1...4 {
                    #expect(view.visibleCardObjectIdentifier(forMediaIndex: index) == stableIDs[index - 1])
                }
                view.handlePan(state: .began, translationX: 0, velocityX: 100)
                view.handlePan(state: .ended, translationX: width * 0.7, velocityX: 0, animated: false)
                #expect(view.frontMediaIndex == 2)
                for index in 1...4 {
                    #expect(view.visibleCardObjectIdentifier(forMediaIndex: index) == stableIDs[index - 1])
                }
                view.handlePan(state: .began, translationX: 0, velocityX: -100)
                view.handlePan(state: .changed, translationX: -140, velocityX: 0)
                view.frame.size.width = 160
                view.setNeedsLayout()
                view.layoutIfNeeded()
                view.handlePan(state: .ended, translationX: -140, velocityX: -900, animated: false)
                #expect(view.frontMediaIndex == 2)
                #expect(view.visibleCardTransform(forMediaIndex: 2) == .identity)
                view.handlePan(state: .began, translationX: -140, velocityX: -100)
                view.semanticContentAttribute = semantic == .forceLeftToRight ? .forceRightToLeft : .forceLeftToRight
                view.setNeedsLayout()
                view.layoutIfNeeded()
                view.handlePan(state: .ended, translationX: -140, velocityX: 0, animated: false)
                #expect(view.frontMediaIndex == 2)
                #expect(view.visibleCardTransform(forMediaIndex: 2) == .identity)
            }
        }
    }

    /// 收尾阻止重入；复用和同 ID 媒体内容替换后旧完成回调不得写入新绑定。
    @Test func stackAnimationPublishesOnceAndRejectsStaleCompletion() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        let view = makeStackView(fixture.group)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        var changes: [Int] = []
        view.frontIndexDidChange = { _, index in changes.append(index) }
        view.handlePan(state: .began, translationX: 0, velocityX: -100)
        view.handlePan(state: .ended, translationX: -2, velocityX: -600)
        #expect(view.frontMediaIndex == 1)
        #expect(changes == [1])
        view.accessibilityIncrement()
        view.handlePan(state: .began, translationX: -150, velocityX: -900)
        #expect(changes == [1])
        view.reset()
        let replacement = MediaGroupAttachment(id: fixture.group.id, items: Array(fixture.group.items.prefix(2)))
        view.configure(messageID: 99, direction: .incoming, group: replacement, frontIndex: 0, strings: mediaStrings)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(view.frontMediaIndex == 0)
        #expect(changes == [1])
        #expect(view.visibleCardCount == 2)
        #expect(view.visibleCardTransform(forMediaIndex: 0) == .identity)
    }

    /// 旋转卡片外接矩形的空角不应误选媒体，交互阶段不解析预览目标。
    @Test func stackTapUsesTransformedCardCoordinates() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        let view = makeStackView(fixture.group)
        let center = try #require(view.visibleCardCenter(forMediaIndex: 0))
        #expect(view.mediaIndex(at: center) == 0)
        let back = try #require(view.visibleCardFrame(forMediaIndex: 4))
        let transform = try #require(view.visibleCardTransform(forMediaIndex: 4))
        let enclosingRect = CGRect(x: -back.width / 2, y: -back.height / 2, width: back.width, height: back.height)
            .applying(transform).offsetBy(dx: back.midX, dy: back.midY)
        let emptyCorner = CGPoint(x: enclosingRect.maxX - 0.1, y: enclosingRect.maxY - 0.1)
        #expect(view.mediaIndex(at: emptyCorner) == nil)
        view.handlePan(state: .began, translationX: 0, velocityX: -100)
        #expect(view.mediaIndex(at: center) == nil)
        view.handlePan(state: .ended, translationX: -140, velocityX: 0, animated: false)
        #expect(view.mediaIndex(at: try #require(view.visibleCardCenter(forMediaIndex: 1))) == 1)
    }

    /// 提交回调可以同步复用视图；旧路径不得覆盖新组或继续旧动画。
    @Test func stackCommitCanSynchronouslyReconfigureTheView() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5)
        defer { fixture.remove() }
        let view = makeStackView(fixture.group)
        var changeCount = 0
        view.frontIndexDidChange = { _, _ in
            changeCount += 1
            view.configure(messageID: 99, direction: .incoming, group: fixture.group, frontIndex: 4, strings: mediaStrings)
        }
        defer { view.frontIndexDidChange = nil }
        view.handlePan(state: .began, translationX: 0, velocityX: -100)
        view.handlePan(state: .ended, translationX: -150, velocityX: 0, animated: false)
        view.layoutIfNeeded()
        #expect(view.frontMediaIndex == 4)
        #expect(changeCount == 1)
        #expect(view.visibleCardZPosition(forMediaIndex: 4) == 30)
    }

    /// 在真实窗口捕获五个交互阶段，检查整张视频卡片和下一条消息的稳定位置。
    @Test func stackInteractionRendersReferenceStagesInRealWindow() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 5, videoIndices: [0])
        defer { fixture.remove() }
        let colors: [UIColor] = [.systemOrange, .systemBlue, .systemGreen, .systemPurple, .systemPink]
        for (index, item) in fixture.group.items.enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 432, height: 600)).image { context in
                colors[index].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 432, height: 600))
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: 35, y: 35), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 100), .foregroundColor: UIColor.white
                ])
            }
            try image.pngData()?.write(to: item.thumbnailFileURL)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        canvas.backgroundColor = .systemBackground
        host.view.addSubview(canvas)
        let cell = MediaBubbleCell(frame: .zero)
        canvas.addSubview(cell)
        cell.configure(.init(id: 8, direction: .outgoing, attachment: .mediaGroup(fixture.group), deliveryText: "Delivered"),
                       group: fixture.group, frontIndex: 0, strings: mediaStrings)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: 402, height: 52)
        cell.frame = CGRect(origin: CGPoint(x: 0, y: 170), size: cell.preferredLayoutAttributesFitting(attributes).size)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let next = UILabel(frame: CGRect(x: 24, y: cell.frame.maxY + 30, width: 330, height: 50))
        next.text = "下一条消息保持原位"
        canvas.addSubview(next)
        let nextFrame = next.frame
        let cellSize = cell.frame.size
        let view = cell.mediaView
        try await Task.sleep(nanoseconds: 200_000_000)
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { _ in
                canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true)
            }
            Attachment.record(image, named: "media-stack-\(name).png")
            #expect(cell.frame.size == cellSize)
            #expect(next.frame == nextFrame)
        }
        capture("01-resting")
        view.handlePan(state: .began, translationX: 0, velocityX: -100)
        view.handlePan(state: .changed, translationX: -110, velocityX: 0)
        capture("02-dragging")
        view.handlePan(state: .changed, translationX: -140, velocityX: 0)
        capture("03-reordered")
        view.handlePan(state: .changed, translationX: -90, velocityX: 0)
        capture("04-returned")
        view.handlePan(state: .ended, translationX: -140, velocityX: 0, animated: false)
        capture("05-committed")
        #expect(view.frontMediaIndex == 1)
    }

    /// 创建使用真实布局宽度的媒体堆叠，供交互回归复用。
    @available(iOS 26.0, *)
    private func makeStackView(
        _ group: MediaGroupAttachment,
        frontIndex: Int = 0,
        direction: MessageDirection = .outgoing
    ) -> MediaMessageView {
        let view = MediaMessageView()
        view.configure(messageID: 8, direction: direction, group: group, frontIndex: frontIndex, strings: mediaStrings)
        view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutIfNeeded()
        return view
    }

    @Test func stackStateSurvivesReuseAndPrunesDeletedMessages() {
        guard #available(iOS 26.0, *) else { return }
        let store = MediaStackStateStore()
        #expect(store.index(for: 10, itemCount: 5) == 0)
        store.setIndex(3, for: 10, itemCount: 5)
        store.setIndex(1, for: 11, itemCount: 2)
        #expect(store.index(for: 10, itemCount: 5) == 3)
        store.retainMessages([11])
        #expect(store.index(for: 10, itemCount: 5) == 0)
        #expect(store.index(for: 11, itemCount: 2) == 1)
    }

    @Test func mediaDraftFilesCommitOrDiscardAsOneAttachment() throws {
        guard #available(iOS 26.0, *) else { return }
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatMediaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = PageAttachmentStore(parentDirectory: parent)
        let fixture = try MediaFixture(itemCount: 2, parentDirectory: store.directoryURL)
        let attachment = AzureFish.Attachment.mediaGroup(fixture.group)
        store.registerDraft(attachment)
        #expect(store.commitDraft(id: fixture.group.id))
        #expect(fixture.group.localFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        store.removeAll()
        #expect(fixture.group.localFileURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(arguments: [false, true])
    func deselectingLastPhotoClearsDraftAndCancelsImport(isImporting: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1)
        defer { fixture.remove() }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let controller = PhotoPickerController(attachmentStore: store)
        controller.applyPreviewFixture(fixture.group)
        let entry = try #require(controller.entries.first)
        let progress = Progress(totalUnitCount: 100)
        if isImporting {
            entry.content = .importing
            entry.progress = progress
            controller.pendingImports = [.init(provider: NSItemProvider(), entry: entry, generation: controller.generation)]
        }
        var configuration = PHPickerConfiguration()
        configuration.selection = .continuousAndOrdered
        let picker = PHPickerViewController(configuration: configuration)
        controller.picker = picker
        let composer = ComposerView(frame: .zero)
        let emptyHeight = composer.intrinsicContentSize.height
        composer.applyMediaDraft(controller.draft, animated: false)
        var didPublishEmpty = false
        controller.stateDidChange = { draft in
            didPublishEmpty = draft == nil
            composer.applyMediaDraft(draft, animated: false)
        }
        controller.picker(picker, didFinishPicking: [])
        #expect(didPublishEmpty)
        #expect(controller.entries.isEmpty)
        #expect(controller.pendingImports.isEmpty)
        #expect(controller.draftAttachment == nil)
        #expect(composer.mediaDraft == nil)
        #expect(composer.intrinsicContentSize.height == emptyHeight)
        #expect(!composer.hasSendableContent)
        #expect(controller.picker === picker)
        if isImporting { #expect(progress.isCancelled) }
        else { #expect(fixture.group.localFileURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }) }
    }

    @Test func dismissedPhotoPickerCannotClearCurrentDraft() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 1)
        defer { fixture.remove() }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let controller = PhotoPickerController(attachmentStore: store)
        controller.applyPreviewFixture(fixture.group)
        let oldPicker = PHPickerViewController(configuration: PHPickerConfiguration())
        controller.picker = PHPickerViewController(configuration: PHPickerConfiguration())
        controller.picker(oldPicker, didFinishPicking: [])
        #expect(controller.draft?.items.map(\.id) == fixture.group.items.map(\.id))
    }

    /// 系统关闭和主动关闭都只隐藏面板，保留已选资源及尚未完成的导入。
    @Test(arguments: [false, true])
    func photoDismissalPreservesDraftAndIgnoresStaleCallbacks(interactive: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 2)
        defer { fixture.remove() }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let controller = PhotoPickerController(attachmentStore: store)
        controller.applyPreviewFixture(fixture.group)
        let entry = try #require(controller.entries.last)
        let progress = Progress(totalUnitCount: 100)
        entry.content = .importing
        entry.progress = progress
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        entry.task = task
        defer { task.cancel() }
        controller.pendingImports = [.init(provider: NSItemProvider(), entry: entry, generation: controller.generation)]
        let originalDraft = try #require(controller.draft)
        let generation = controller.generation
        let presenter = UIViewController()
        let window = try makeVisibleTestWindow(rootViewController: presenter)
        defer { window.isHidden = true }
        var dismissCount = 0
        var stateChangeCount = 0
        controller.pickerDidDismiss = {
            dismissCount += 1
            #expect(!controller.isPresented)
            #expect(controller.picker == nil)
        }
        controller.stateDidChange = { _ in stateChangeCount += 1 }
        controller.present(from: presenter, keyboardHeight: 300)
        try await Task.sleep(nanoseconds: 600_000_000)
        let host = try #require(presenter.presentedViewController)
        let presentation = try #require(host.presentationController)
        let oldPicker = try #require(controller.picker)
        #expect(!host.isModalInPresentation)
        if interactive {
            // 手势本身由 UI 测试覆盖；这里验证系统关闭完成回调的生命周期语义。
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
            controller.presentationControllerDidDismiss(presentation)
        } else {
            await withCheckedContinuation { continuation in
                controller.dismissPicker(animated: false) { continuation.resume() }
            }
        }
        controller.presentationControllerDidDismiss(presentation)
        controller.picker(oldPicker, didFinishPicking: [])
        #expect(dismissCount == 1)
        #expect(stateChangeCount == 0)
        #expect(!controller.isPresented)
        #expect(controller.picker == nil)
        #expect(controller.draft?.groupID == originalDraft.groupID)
        #expect(controller.draft?.items.map(\.id) == originalDraft.items.map(\.id))
        #expect(controller.generation == generation)
        #expect(controller.pendingImports.count == 1)
        #expect(!progress.isCancelled)
        #expect(!task.isCancelled)
        #expect(fixture.group.localFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        controller.present(from: presenter, keyboardHeight: 300)
        try await Task.sleep(nanoseconds: 600_000_000)
        let newPicker = try #require(controller.picker)
        #expect(newPicker !== oldPicker)
        #expect(newPicker.configuration.preselectedAssetIdentifiers == controller.entries.compactMap(\.assetIdentifier))
        controller.presentationControllerDidDismiss(presentation)
        controller.picker(oldPicker, didFinishPicking: [])
        #expect(controller.isPresented)
        #expect(controller.picker === newPicker)
        #expect(dismissCount == 1)
        #expect(stateChangeCount == 0)
        await withCheckedContinuation { continuation in
            controller.dismissPicker(animated: false) { continuation.resume() }
        }
        #expect(dismissCount == 2)
    }

    /// 提交消费草稿并保留面板实例与档位，后续丢弃空草稿不能删除已发送原件。
    @Test func committingPhotoDraftKeepsPresentedSheetAndCommittedFiles() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 2, hasAssetIdentifiers: false)
        defer { fixture.remove() }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let controller = PhotoPickerController(attachmentStore: store)
        controller.applyPreviewFixture(fixture.group)
        let presenter = UIViewController()
        let window = try makeVisibleTestWindow(rootViewController: presenter)
        defer { window.isHidden = true }
        var dismissCount = 0
        controller.pickerDidDismiss = { dismissCount += 1 }
        controller.present(from: presenter, keyboardHeight: 300)
        try await Task.sleep(nanoseconds: 600_000_000)
        let host = try #require(presenter.presentedViewController)
        let sheet = try #require(host.sheetPresentationController)
        sheet.selectedDetentIdentifier = .large
        #expect(controller.commitDraft())
        #expect(controller.draft == nil)
        #expect(controller.isPresented)
        #expect(presenter.presentedViewController === host)
        #expect(sheet.selectedDetentIdentifier == .large)
        #expect(dismissCount == 0)
        #expect(!controller.commitDraft())
        controller.discardDraft()
        #expect(fixture.group.localFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        controller.dismissPicker(animated: false)
    }

    @Test func mediaBodyMeasuresBeforeLayoutAcrossWidthsAndDirections() throws {
        guard #available(iOS 26.0, *) else { return }
        for count in [1, 3] {
            let fixture = try MediaFixture(itemCount: count)
            defer { fixture.remove() }
            for direction in [MessageDirection.incoming, .outgoing] {
                for rtl in [false, true] {
                    let cell = MediaBubbleCell(frame: .zero)
                    cell.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    cell.configure(.init(id: 1, direction: direction, attachment: .mediaGroup(fixture.group),
                                         deliveryText: direction == .outgoing ? "已读" : nil),
                                   group: fixture.group, frontIndex: 0, strings: mediaStrings)
                    for width: CGFloat in [402, 200, 320] {
                        let proposed = CGSize(width: width, height: 52)
                        let measured = cell.sizeThatFits(proposed)
                        let attributes = UICollectionViewLayoutAttributes(forCellWith: .init(item: 0, section: 0))
                        attributes.size = proposed
                        #expect(abs(cell.preferredLayoutAttributesFitting(attributes).size.height - measured.height) < 1)
                        cell.frame.size = measured
                        cell.setNeedsQuickLayout()
                        cell.layoutIfNeeded()
                        let media = cell.mediaView.convert(cell.mediaView.bounds, to: cell)
                        #expect(media.minX >= 11 && media.maxX <= width - 11)
                        #expect(media.maxY <= measured.height - 3)
                        #expect(cell.mediaView.headerHeight == (count > 1 ? 32 : 0))
                        if direction == .incoming {
                            let save = cell.saveButton.convert(cell.saveButton.bounds, to: cell)
                            #expect(save.width == 44 && save.height == 44)
                            #expect(save.minX >= 11 && save.maxX <= width - 11)
                            let gap = rtl ? media.minX - save.maxX : save.minX - media.maxX
                            #expect(abs(gap - 8) < 1)
                        }
                        let natural = cell.mediaView.intrinsicContentSize
                        let header = cell.mediaView.headerHeight
                        #expect(abs((media.height - header) / (natural.height - header) - media.width / natural.width) < 0.01)
                    }
                }
            }
        }
    }

    @Test func outgoingMediaGroupFitsInsideIPhone16ProMessageRow() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3)
        defer { fixture.remove() }
        let cell = MediaBubbleCell(frame: .zero)
        cell.configure(
            MessagePresentation(
                id: 3,
                direction: .outgoing,
                attachment: .mediaGroup(fixture.group),
                deliveryText: "Delivered"
            ),
            group: fixture.group,
            frontIndex: 0,
            strings: mediaStrings
        )
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.size = CGSize(width: 402, height: 52)
        let fitted = cell.preferredLayoutAttributesFitting(attributes)
        cell.frame = CGRect(origin: .zero, size: fitted.size)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let frame = cell.mediaView.convert(cell.mediaView.bounds, to: cell)
        #expect(frame.width == 232)
        #expect(frame.height == 349)
        #expect(frame.minX >= 12)
        #expect(frame.maxX <= 390)
        #expect(abs(frame.maxX - 390) < 1)
        #expect(fitted.size.height >= frame.height + 20)
        #expect(fitted.size.height <= frame.height + 40)
        #expect(frame.maxY < fitted.size.height)
    }

    @Test(arguments: [false, true])
    func mixedIncomingReplyReservesVisibleMediaFileAndTextBounds(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3)
        defer { fixture.remove() }
        let host = UIViewController()
        let conversation = ConversationView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        host.view = conversation
        let window = try makeVisibleTestWindow(rootViewController: host)
        defer { window.isHidden = true; window.rootViewController = nil }
        conversation.applyLayoutDirection(rtl ? .rightToLeft : .leftToRight)
        let audioFile = FileAttachment(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/reply.m4a"),
            displayName: "Audio Message.m4a", typeIdentifier: "public.mpeg-4-audio", byteCount: 83_000)
        let rows: [TimelineItem] = [
            .init(id: .message(1), content: .message(.init(id: 1, direction: .incoming, attachment: .mediaGroup(fixture.group), deliveryText: nil))),
            .init(id: .message(2), content: .message(.init(id: 2, direction: .incoming, attachment: .file(audioFile), deliveryText: nil))),
            .init(id: .message(3), content: .message(.init(id: 3, direction: .incoming, text: "好呀，一会儿见！", deliveryText: nil))),
        ]
        conversation.render(.init(timeline: rows, isTyping: false), reason: .receivedMessage)
        try await Task.sleep(nanoseconds: 500_000_000)
        let collection = conversation.collectionView
        collection.layoutIfNeeded()
        let mediaCell = try #require(collection.cellForItem(at: .init(item: 0, section: 0)) as? MediaBubbleCell)
        let fileCell = try #require(collection.cellForItem(at: .init(item: 1, section: 0)) as? DocumentBubbleCell)
        let textCell = try #require(collection.cellForItem(at: .init(item: 2, section: 0)) as? TextBubbleCell)
        let cardBounds = mediaCell.mediaView.cards.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: collection) }
        let fileBounds = fileCell.card.convert(fileCell.card.bounds, to: collection)
        let textBounds = textCell.bubbleView.convert(textCell.bubbleView.bounds, to: collection)
        let mediaBounds = cardBounds.reduce(CGRect.null) { $0.union($1) }
        #expect(mediaBounds.maxY <= mediaCell.frame.maxY, "Rotated stack exceeds row: \(mediaBounds) / \(mediaCell.frame)")
        #expect(fileBounds.maxY <= fileCell.frame.maxY, "File exceeds row: \(fileBounds) / \(fileCell.frame)")
        #expect(textBounds.maxY <= textCell.frame.maxY, "Text exceeds row: \(textBounds) / \(textCell.frame)")
        #expect(fileBounds.minY - mediaBounds.maxY >= 6, "Media overlaps file: \(mediaBounds) / \(fileBounds)")
        #expect(textBounds.minY - fileBounds.maxY >= 6, "File overlaps text: \(fileBounds) / \(textBounds)")
    }

    @Test func adjacentMediaRowsReserveTheirFullHeightInLiveConversation() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 6)
        defer { fixture.remove() }
        let host = UIViewController()
        let conversation = ConversationView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        host.view = conversation
        let window = try makeVisibleTestWindow(rootViewController: host)
        defer { window.isHidden = true; window.rootViewController = nil }
        let rows: [TimelineItem] = [
            .init(id: .message(1), content: .message(.init(id: 1, direction: .incoming, text: "Before attachments", deliveryText: nil))),
            .init(id: .message(2), content: .message(.init(id: 2, direction: .outgoing, attachment: .mediaGroup(fixture.group), deliveryText: "Read"))),
            .init(id: .message(3), content: .message(.init(id: 3, direction: .incoming, attachment: .mediaGroup(fixture.group), deliveryText: nil))),
        ]
        conversation.render(.init(timeline: rows, isTyping: false), reason: .initial)
        // Allow diffable data source and compositional self-sizing to complete in a real window.
        try await Task.sleep(nanoseconds: 500_000_000)
        let collection = conversation.collectionView
        collection.layoutIfNeeded()
        let first = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        let second = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
        #expect(first.frame.height >= 350)
        #expect(second.frame.height >= 340)
        #expect(first.frame.maxY <= second.frame.minY)
        for cell in collection.visibleCells.compactMap({ $0 as? MediaBubbleCell }) {
            let media = cell.mediaView.convert(cell.mediaView.bounds, to: cell)
            #expect(media.minY >= 0)
            #expect(media.maxY <= cell.bounds.height)
        }
    }

    @Test func bottomObstructionExcludesTheContainerSafeArea() {
        guard #available(iOS 26.0, *) else { return }
        #expect(
            BottomObstructionCoordinator.contentObstruction(
                containerMaxY: 874,
                obstructionMinY: 540,
                safeAreaBottom: 34
            ) == 300
        )
        #expect(
            BottomObstructionCoordinator.contentObstruction(
                containerMaxY: 874,
                obstructionMinY: 874,
                safeAreaBottom: 34
            ) == 0
        )
    }

    @Test func photoSheetFollowsBothDirectionsAndStopsAtLatestKeyboardHeight() {
        guard #available(iOS 26.0, *) else { return }
        for (pickerHeight, limit, expected): (CGFloat, CGFloat, CGFloat) in [
            (0, 300, 0), (120, 300, 120), (300, 300, 300),
            (760, 300, 300), (180, 300, 180), (0, 300, 0),
            (760, 336, 336), (300, 200, 200), (-20, 300, 0),
        ] {
            #expect(
                BottomObstructionCoordinator.resolvedObstruction(
                    keyboardHeight: 760,
                    pickerHeight: pickerHeight,
                    maximumPickerHeight: limit
                ) == expected
            )
        }
    }

    @Test func photoSheetGeometryTracksItsContainerAndIgnoresKeyboardHide() throws {
        guard #available(iOS 26.0, *) else { return }
        let window = try makeObstructionTestWindow()
        let hostView = UIView(frame: window.bounds)
        let sheetContainer = UIView(frame: window.bounds)
        let picker = UIViewController()
        picker.view = UIView(frame: window.bounds)
        window.addSubview(hostView)
        window.addSubview(sheetContainer)
        sheetContainer.addSubview(picker.view)
        let coordinator = BottomObstructionCoordinator(hostView: hostView)
        defer { coordinator.stop() }
        coordinator.trackPicker(picker)
        #expect(!coordinator.updateKeyboard(.hidden))

        // 模拟系统通过父容器移动 Sheet，确保读取的是宿主坐标中的实际位置。
        for height: CGFloat in [0, 120, 300, 650, 180, 0] {
            sheetContainer.transform = CGAffineTransform(
                translationX: 0,
                y: hostView.bounds.maxY - hostView.safeAreaInsets.bottom - height
            )
            coordinator.refreshGeometry()
            #expect(abs(coordinator.currentHeight - min(height, 300)) < 0.5)
        }
        coordinator.stopTrackingPicker()
        #expect(coordinator.currentHeight == 0)
    }

    @Test func latestFullKeyboardFrameUpdatesPhotoCapWithoutCachingDismissal() throws {
        guard #available(iOS 26.0, *) else { return }
        let window = try makeObstructionTestWindow()
        let hostView = UIView(frame: window.bounds)
        window.addSubview(hostView)
        let coordinator = BottomObstructionCoordinator(hostView: hostView)
        defer { coordinator.stop() }

        func update(height: CGFloat, downwardOffset: CGFloat = 0) throws {
            let frame = CGRect(x: 0, y: 844 - height + downwardOffset, width: 390, height: height)
            let notification = Notification(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: window.screen,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey:
                        window.convert(frame, to: window.screen.coordinateSpace),
                    UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                ]
            )
            coordinator.updateKeyboard(try #require(
                QuickLayoutKeyboardContext(notification: notification)
            ))
        }
        try update(height: 334)
        #expect(coordinator.storedKeyboardContentHeight == 334 - hostView.safeAreaInsets.bottom)
        try update(height: 370)
        #expect(coordinator.storedKeyboardContentHeight == 370 - hostView.safeAreaInsets.bottom)
        try update(height: 240)
        #expect(coordinator.storedKeyboardContentHeight == 240 - hostView.safeAreaInsets.bottom)
        try update(height: 240, downwardOffset: 100)
        coordinator.updateKeyboard(.hidden)
        #expect(coordinator.storedKeyboardContentHeight == 240 - hostView.safeAreaInsets.bottom)

        // 复现键盘进入照片面板后，附件菜单关闭又报告较小键盘高度的顺序。
        let picker = UIViewController()
        coordinator.trackPicker(picker)
        try update(height: 210)
        #expect(coordinator.storedKeyboardContentHeight == 240 - hostView.safeAreaInsets.bottom)
        coordinator.updateKeyboard(.hidden)
        #expect(coordinator.storedKeyboardContentHeight == 240 - hostView.safeAreaInsets.bottom)

        // 用户切回键盘后，新高度重新成为后续照片面板的上限。
        coordinator.beginKeyboardHandoff()
        try update(height: 370)
        #expect(coordinator.storedKeyboardContentHeight == 370 - hostView.safeAreaInsets.bottom)
    }

    @Test func keyboardToPhotoPresentationHoldsHeightThenTracksCalibratedGeometry() throws {
        guard #available(iOS 26.0, *) else { return }
        let window = try makeObstructionTestWindow()
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        let coordinator = BottomObstructionCoordinator(hostView: host)
        defer { coordinator.stop() }
        let keyboardFrame = CGRect(x: 0, y: 510, width: 390, height: 334)
        let notification = Notification(
            name: UIResponder.keyboardWillShowNotification,
            object: window.screen,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey:
                    window.convert(keyboardFrame, to: window.screen.coordinateSpace),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            ]
        )
        coordinator.updateKeyboard(try #require(QuickLayoutKeyboardContext(notification: notification)))
        let keyboardHeight = coordinator.storedKeyboardContentHeight
        let picker = UIViewController()
        picker.view = UIView(frame: window.bounds)
        window.addSubview(picker.view)

        func setPickerHeight(_ height: CGFloat) {
            picker.view.frame.origin.y = host.bounds.maxY - host.safeAreaInsets.bottom - height
            coordinator.refreshGeometry()
        }
        setPickerHeight(-34)
        coordinator.trackPicker(picker)
        coordinator.updateKeyboard(.hidden)
        // 面板入场时即使逐帧经过屏幕外和中间高度，输入栏也始终保持键盘等高。
        for height in [-34, 60, 180, keyboardHeight - 6] {
            setPickerHeight(height)
            #expect(abs(coordinator.currentHeight - keyboardHeight) < 0.5)
        }
        // 完成回调不能产生小幅下移；后续拖动仍生效，且受同一键盘高度上限约束。
        coordinator.finishPickerPresentation(picker)
        #expect(abs(coordinator.currentHeight - keyboardHeight) < 0.5)
        setPickerHeight(600)
        #expect(abs(coordinator.currentHeight - keyboardHeight) < 0.5)
        setPickerHeight(180)
        #expect(abs(coordinator.currentHeight - 186) < 0.5)
        coordinator.finishPickerPresentation(UIViewController())
        #expect(abs(coordinator.currentHeight - 186) < 0.5)
        // 关闭时校准量也必须随面板完全离屏归零，不能残留到关闭完成才突变。
        setPickerHeight(-34)
        #expect(coordinator.currentHeight == 0)
        coordinator.stopTrackingPicker()
        #expect(coordinator.currentHeight == 0)
    }

    /// 复用测试宿主的场景创建隐藏窗口，独立验证几何且不抢占页面焦点。
    @available(iOS 26.0, *)
    private func makeObstructionTestWindow() throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return window
    }

    @Test func photoSheetOwnsComposerUntilKeyboardHandoffBegins() {
        guard #available(iOS 26.0, *) else { return }
        #expect(
            !BottomObstructionCoordinator.shouldApplyKeyboardLayout(
                isPickerPresented: true,
                isAwaitingKeyboard: false
            )
        )
        #expect(
            BottomObstructionCoordinator.shouldApplyKeyboardLayout(
                isPickerPresented: true,
                isAwaitingKeyboard: true
            )
        )
        #expect(
            BottomObstructionCoordinator.shouldApplyKeyboardLayout(
                isPickerPresented: false,
                isAwaitingKeyboard: false
            )
        )
        #expect(
            BottomObstructionCoordinator.shouldTrackGeometry(
                isPickerPresented: true,
                isAwaitingKeyboard: false,
                keyboardIsVisible: false
            )
        )
        #expect(
            BottomObstructionCoordinator.shouldTrackGeometry(
                isPickerPresented: true,
                isAwaitingKeyboard: true,
                keyboardIsVisible: true
            )
        )
        #expect(
            BottomObstructionCoordinator.shouldTrackGeometry(
                isPickerPresented: false,
                isAwaitingKeyboard: false,
                keyboardIsVisible: true
            )
        )
        #expect(
            !BottomObstructionCoordinator.shouldTrackGeometry(
                isPickerPresented: false,
                isAwaitingKeyboard: false,
                keyboardIsVisible: false
            )
        )
    }

    @Test func keyboardAndPhotoHandoffsKeepOneStableObstructionHeight() {
        guard #available(iOS 26.0, *) else { return }
        #expect(
            BottomObstructionCoordinator.resolvedObstruction(
                keyboardHeight: 96,
                pickerHeight: 300,
                maximumPickerHeight: 300
            ) == 300
        )
        #expect(
            BottomObstructionCoordinator.resolvedObstruction(
                keyboardHeight: 24,
                pickerHeight: 300,
                maximumPickerHeight: 300
            ) == 300
        )
        #expect(
            BottomObstructionCoordinator.resolvedObstruction(
                keyboardHeight: 18,
                pickerHeight: nil,
                maximumPickerHeight: 300,
                isAwaitingKeyboard: true,
                keyboardHandoffStartHeight: 300,
                keyboardHandoffTargetHeight: nil
            ) == 300
        )
        #expect(
            BottomObstructionCoordinator.resolvedObstruction(
                keyboardHeight: 84,
                pickerHeight: 300,
                maximumPickerHeight: 300,
                isAwaitingKeyboard: true,
                keyboardHandoffStartHeight: 300,
                keyboardHandoffTargetHeight: 336
            ) == 336
        )
        #expect(
            BottomObstructionCoordinator.resolvedObstruction(
                keyboardHeight: 336,
                pickerHeight: nil,
                maximumPickerHeight: 300
            ) == 336
        )
    }

    @Test func mediaQuickLayoutTransitionsPreserveMasksAndVideoOverlays() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3, videoIndices: [0])
        defer { fixture.remove() }
        let view = MediaMessageView()
        func configure(_ items: [MediaItem]) {
            let group = MediaGroupAttachment(id: fixture.group.id, items: items)
            view.configure(messageID: 8, direction: .outgoing, group: group, frontIndex: 0, strings: mediaStrings)
            view.frame.size = view.intrinsicContentSize
            view.layoutIfNeeded()
            view.cards.forEach { $0.layoutIfNeeded() }
        }

        configure([fixture.group.items[0]])
        let video = try #require(view.cards.first)
        let mask = try #require(video.mask as? QuickLayoutShapeView)
        #expect(mask.bounds == video.bounds)
        #expect(video.layer.cornerRadius == 0)
        #expect((mask.layer as? CAShapeLayer)?.path != nil)
        #expect(video.imageView.frame == video.bounds)
        #expect(video.playBackground.isDescendant(of: video))
        #expect(video.playBackground.bounds.size == CGSize(width: 48, height: 48))
        video.playBackground.layoutIfNeeded()
        #expect(video.playImageView.superview === video.playBackground.contentView)
        #expect(video.playImageView.frame == CGRect(x: 15, y: 13, width: 18, height: 22))
        #expect(view.itemCountLabel.superview == nil)
        #expect(view.itemCountIcon.superview == nil)

        configure(fixture.group.items)
        #expect(view.cards.allSatisfy { $0.mask == nil && $0.isDescendant(of: view) })
        #expect(view.cards.allSatisfy { $0.layer.cornerRadius == MediaMessageView.Metrics.cornerRadius })
        #expect(view.itemCountLabel.isDescendant(of: view))
        #expect(view.itemCountIcon.isDescendant(of: view))

        configure([fixture.group.items[1]])
        let image = try #require(view.cards.first)
        #expect(image.mask === mask)
        #expect(image.layer.cornerRadius == 0)
        #expect(image.playBackground.superview == nil)
        #expect(view.itemCountLabel.superview == nil)
        #expect(view.itemCountIcon.superview == nil)

        view.reset()
        view.layoutIfNeeded()
        #expect(view.cards.allSatisfy { $0.superview == nil && $0.mask == nil })
        #expect(mask.shape == nil)
        configure([fixture.group.items[0]])
        #expect(view.cards.first?.playBackground.isDescendant(of: view) == true)
    }

    @Test func mediaGroupTitleMirrorsWithSemanticOuterEdge() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = try MediaFixture(itemCount: 3)
        defer { fixture.remove() }
        let view = MediaMessageView()
        view.configure(
            messageID: 3,
            direction: .outgoing,
            group: fixture.group,
            frontIndex: 0,
            strings: mediaStrings
        )
        view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutIfNeeded()
        #expect(abs(view.itemCountLabel.frame.maxX - view.bounds.maxX) < 1)

        view.semanticContentAttribute = .forceRightToLeft
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(abs(view.itemCountLabel.frame.minX - 22) < 1)
    }

    @available(iOS 26.0, *)
    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            localizer: Localizer { key, _ in "localized.\(key)" },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            sleeper: { duration in try await Task.sleep(for: duration) }
        )
    }

    @available(iOS 26.0, *)
    private func messagePresentations(
        in state: ChatViewModel.State
    ) -> [MessagePresentation] {
        state.timeline.compactMap { item in
            guard case .message(let message) = item.content else { return nil }
            return message
        }
    }

    @available(iOS 26.0, *)
    private var mediaStrings: MediaStrings {
        MediaStrings(
            photo: "Photos",
            itemsFormat: "%d items",
            image: "Image",
            animatedImage: "Animated image",
            video: "Video",
            videoDurationFormat: "Video, duration %@",
            importing: "Importing",
            remove: "Remove",
            play: "Play",
            openPreview: "Open preview",
            close: "Close",
            firstItem: "First",
            lastItem: "Last",
            positionFormat: "%d of %d"
        )
    }
}

@available(iOS 26.0, *)
private final class MediaFixture {
    let directory: URL
    let group: MediaGroupAttachment

    init(
        itemCount: Int,
        videoIndices: Set<Int> = [],
        pixelSizes: [CGSize]? = nil,
        animatedIndices: Set<Int> = [],
        liveIndices: Set<Int> = [],
        hasAssetIdentifiers: Bool = true,
        parentDirectory: URL? = nil
    ) throws {
        directory = parentDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatMediaFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var items: [MediaItem] = []
        for index in 0..<itemCount {
            let original = directory.appendingPathComponent("original-\(index).dat")
            let thumbnail = directory.appendingPathComponent("thumbnail-\(index).jpg")
            try Data([UInt8(index % 255)]).write(to: original)
            try Data([UInt8((index + 1) % 255)]).write(to: thumbnail)
            items.append(
                MediaItem(
                    assetIdentifier: hasAssetIdentifiers ? "asset-\(index)" : nil,
                    originalFileURL: original,
                    thumbnailFileURL: thumbnail,
                    pixelSize: pixelSizes?[safe: index]
                        ?? CGSize(width: 1200 + index, height: 1600),
                    kind: videoIndices.contains(index)
                        ? .video(duration: TimeInterval(index + 1))
                        : .image,
                    isAnimatedImage: animatedIndices.contains(index),
                    livePhotoVideoURL: liveIndices.contains(index) ? directory.appendingPathComponent("paired-\(index).mov") : nil
                )
            )
        }
        group = MediaGroupAttachment(items: items)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@available(iOS 26.0, *)
private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
