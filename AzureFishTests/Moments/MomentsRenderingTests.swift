import AzureFishAPI
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized)
/// 检查重复配置、外观变化与权限撤回时的图片复用和缓存边界。
struct MomentsRenderingTests {
    @Test func paginationSpinnerCentersAndStopsWhenStateChanges() throws {
        let view = MomentsPaginationView(configuration: MomentsPaginationConfiguration(state: .loading))
        for width in [CGFloat(320), 1200] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 64); view.layoutIfNeeded()
            let spinner = try #require(descendants(view, UIActivityIndicatorView.self).first)
            #expect(spinner.isAnimating)
            #expect(abs(spinner.convert(spinner.bounds, to: view).midX - width / 2) < 1)
        }
        let spinner = try #require(descendants(view, UIActivityIndicatorView.self).first)
        view.configuration = MomentsPaginationConfiguration(state: .failed); view.layoutIfNeeded()
        #expect(!spinner.isAnimating)
        #expect(descendants(view, UILabel.self).first?.text == MomentsPaginationState.failed.label)
        view.configuration = MomentsPaginationConfiguration(state: .ended); view.layoutIfNeeded()
        #expect(!spinner.isAnimating)
        #expect(!MomentsPaginationState.ended.allowsRetry)
    }

    @Test func postImagesSurviveConfigurationAndInteractionChanges() async throws {
        let runtime = MomentsPreviewData.runtime(imageCount: 4)
        var post = runtime.posts[0]
        var selected = -1
        let selfRuntime = runtime
        func config(width: CGFloat = 390, runtime: MomentsRuntime? = nil) -> MomentsPostConfiguration {
            .init(post: post, media: MomentsMediaProvider(runtime: runtime ?? selfRuntime), width: width, expanded: width > 390,
                  action: { if case .photo(let index) = $0 { selected = index } })
        }
        let view = MomentsPostContentView(configuration: config())
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 1500); view.layoutIfNeeded()
        let buttons = photos(view)
        #expect(buttons.count == 4)
        // 重复配置也覆盖尚未完成的异步加载。
        view.configuration = config()
        try await loaded(buttons)
        let images = buttons.compactMap { $0.image(for: .normal) }
        // 新内容视图同步命中缓存，首帧就是图片，不等待 Task 或显示默认图。
        let reused = MomentsPostContentView(configuration: config())
        reused.frame = view.frame; reused.layoutIfNeeded()
        for (index, button) in photos(reused).enumerated() { #expect(button.image(for: .normal) === images[index]) }

        post.likes = []; post.comments = []; post.revision += 1
        for width in [CGFloat(390), 720, 390] {
            view.configuration = config(width: width)
            view.frame.size.width = width; view.layoutIfNeeded()
            for (index, button) in photos(view).enumerated() {
                #expect(button === buttons[index])
                #expect(button.image(for: .normal) === images[index])
            }
        }
        buttons[2].sendActions(for: .touchUpInside); #expect(selected == 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(buttons[0].image(for: .normal) === images[0])

        post.images[0].version += 1
        view.configuration = config()
        #expect(buttons[0].image(for: .normal) == nil)
        #expect(buttons[1].image(for: .normal) === images[1])
        try await loaded(buttons)
        let other = MomentsRuntime(preview: [post], user: "another-account")
        view.configuration = config(runtime: other)
        #expect(buttons.allSatisfy { $0.image(for: .normal) == nil })
        post.images = []
        view.configuration = config(runtime: other); view.layoutIfNeeded()
        #expect(photos(view).isEmpty)
    }

    @Test func coverSurvivesProfileChangesButReplacementAndResetClearIt() async throws {
        var album = MomentsAlbum(owner: MomentsPreviewData.user, cover: MomentsPreviewData.images[0])
        let runtime = MomentsRuntime(preview: MomentsPreviewData.posts, user: album.owner.id, albums: [album])
        func config() -> MomentsHeaderConfiguration { .init(album: album, media: MomentsMediaProvider(runtime: runtime), open: { _ in }) }
        let view = MomentsHeaderView(configuration: config())
        view.frame = CGRect(x: 0, y: 0, width: 720, height: 320); view.layoutIfNeeded()
        let button = try #require(descendants(view, UIButton.self).first { $0.accessibilityIdentifier == "moments.cover" })
        try await loaded([button])
        let image = try #require(button.image(for: .normal))
        album.owner.nickname = "Changed name"; album.revision += 1
        view.configuration = config(); view.layoutIfNeeded()
        #expect(button.image(for: .normal) === image)
        let reused = MomentsHeaderView(configuration: config())
        reused.frame = view.frame; reused.layoutIfNeeded()
        #expect(descendants(reused, UIButton.self).first { $0.accessibilityIdentifier == "moments.cover" }?.image(for: .normal) === image)
        album.cover = MomentsPreviewData.images[1]
        view.configuration = config()
        #expect(button.image(for: .normal) == nil)
        try await loaded([button])
        album.cover = nil; view.configuration = config()
        #expect(button.image(for: .normal)?.isSymbolImage == true)
        #expect(button.contentHorizontalAlignment == .center)
    }

    @Test func listAppearanceAndCellStateKeepImagesAndRevocationRemovesRows() async throws {
        let runtime = MomentsPreviewData.runtime(imageCount: 4)
        let controller = MomentsViewController(runtime: runtime)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 1600); controller.view.layoutIfNeeded()
        let list = try #require(descendants(controller.view, UICollectionView.self).first)
        #expect(list.convert(list.bounds, to: controller.view) == controller.view.bounds)
        list.layoutIfNeeded()
        let cell = try #require(list.visibleCells.first { $0.accessibilityIdentifier?.hasPrefix("moment.row.") == true })
        let buttons = photos(cell); #expect(buttons.count == 4)
        try await loaded(buttons)
        let image = try #require(buttons.first?.image(for: .normal))
        for _ in 0..<3 {
            controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
            controller.reloadLocalizedContent()
            cell.isHighlighted = true; cell.updateConfiguration(using: cell.configurationState)
            cell.isHighlighted = false; cell.updateConfiguration(using: cell.configurationState)
            controller.view.layoutIfNeeded(); list.layoutIfNeeded()
            #expect(photos(cell).first === buttons.first)
            #expect(buttons.first?.image(for: .normal) === image)
        }
        #expect(runtime.cachedThumbnail(runtime.posts[0].images[0], target: runtime.posts[0].id) === image)
        let post = runtime.posts[0]
        await runtime.stop().value
        #expect(runtime.cachedThumbnail(post.images[0], target: post.id) == nil)
        list.layoutIfNeeded()
        #expect(buttons.allSatisfy { $0.image(for: .normal) == nil })
        #expect(!list.visibleCells.contains { $0.accessibilityIdentifier?.hasPrefix("moment.row.") == true })
    }

    @Test func thumbnailCacheIsBoundedAndChecksTargetVersionAndAccount() throws {
        let posts = (0..<5).map { index in
            var post = MomentsPreviewData.posts[0]; post.id = "fixture-\(index)"; return post
        }
        let runtime = MomentsRuntime(preview: posts, user: MomentsPreviewData.user.id)
        let image = try #require(UIImage(data: MomentsPreviewData.image(1)))
        for post in posts {
            for asset in post.images { runtime.cacheThumbnail(image, asset: asset, target: post.id) }
        }
        #expect(runtime.cachedThumbnail(posts[0].images[0], target: posts[0].id) == nil)
        #expect(runtime.cachedThumbnail(posts[4].images[0], target: posts[4].id) === image)
        #expect(runtime.cachedThumbnail(posts[4].images[0], target: "unavailable") == nil)
        var changed = posts[4].images[0]; changed.version += 1
        #expect(runtime.cachedThumbnail(changed, target: posts[4].id) == nil)
        let other = MomentsRuntime(preview: posts, user: "another-account")
        #expect(other.cachedThumbnail(posts[4].images[0], target: posts[4].id) == nil)
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, type) }
    }
    private func photos(_ view: UIView) -> [UIButton] {
        descendants(view, UIButton.self).filter { $0.accessibilityIdentifier?.hasPrefix("moments.photo.") == true }
            .sorted { ($0.accessibilityIdentifier ?? "") < ($1.accessibilityIdentifier ?? "") }
    }
    private func loaded(_ buttons: [UIButton]) async throws {
        for _ in 0..<100 {
            if buttons.allSatisfy({ $0.image(for: .normal)?.isSymbolImage == false }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("朋友圈图片未完成加载")
    }
}
