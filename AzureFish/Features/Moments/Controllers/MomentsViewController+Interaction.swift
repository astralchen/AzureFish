import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

extension MomentsViewController {
    func compose() {
        let drafts = runtime.availableDrafts()
        guard !drafts.isEmpty else { openComposer(MomentsDraft()); return }
        let alert = UIAlertController(title: Localization.text("moments.drafts"), message: nil, preferredStyle: .actionSheet)
        for draft in drafts.prefix(8) {
            let title = draft.text.isEmpty ? Localization.text("moments.photoDraft") : String(draft.text.prefix(40))
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.openComposer(draft) })
        }
        alert.addAction(UIAlertAction(title: Localization.text("moments.newPost"), style: .default) { [weak self] _ in self?.openComposer(MomentsDraft()) })
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem; present(alert, animated: true)
    }
    /// 取得进程内草稿占用后打开编辑器，避免两个窗口同时编辑同一草稿。
    func openComposer(_ draft: MomentsDraft) {
        guard runtime.claim(draft) else { return }
        let controller = MomentsComposerViewController(runtime: runtime, draft: draft)
        present(AppNavigationController(rootViewController: controller), animated: true)
    }
    func action(_ action: MomentsAction, post: MomentsPost) {
        switch action {
        case .expand: viewModel.toggleExpanded(post.id)
        case .author: navigationController?.pushViewController(MomentsViewController(runtime: runtime, author: post.author.id), animated: true)
        case .comment, .reply:
            guard !runtime.offline else { return }
            navigationController?.pushViewController(MomentsCommentViewController(runtime: runtime, post: post.id, reply: action.comment?.author), animated: true)
        case .delete, .deleteComment:
            let alert = UIAlertController(title: Localization.text("moments.deleteConfirm"), message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: Localization.text("moments.delete"), style: .destructive) { [weak self] _ in
                self?.viewModel.submit(.init(kind: action.comment == nil ? .deletePost : .deleteComment, post: post.id, comment: action.comment?.id ?? ""))
            }); present(alert, animated: true)
        case .like: viewModel.submit(.init(kind: .like, post: post.id, liked: !post.likes.contains { $0.id == runtime.userID }))
        case .photo(let index): showPhotos(post, index: index)
        }
    }
    func coverMenu(source: UIView) {
        let alert = UIAlertController(title: Localization.text("moments.cover"), message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: Localization.text("moments.changeCover"), style: .default) { [weak self] _ in
            guard let self else { return }
            let draft = MomentsDraft(); guard runtime.claim(draft) else { return }
            present(AppNavigationController(rootViewController: MomentsComposerViewController(runtime: runtime, draft: draft, cover: true)), animated: true)
        })
        alert.addAction(UIAlertAction(title: Localization.text("moments.resetCover"), style: .destructive) { [weak self] _ in
            guard let self else { return }; viewModel.submit(.init(kind: .cover, revision: runtime.albums[runtime.userID]?.revision ?? 0))
        })
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = source; alert.popoverPresentationController?.sourceRect = source.bounds
        present(alert, animated: true)
    }
    /// 根据动态媒体类型打开预览；图片预览关闭后将 VoiceOver 焦点交回来源列表。
    func showPhotos(_ post: MomentsPost, index: Int) {
        if post.video != nil { present(MomentsVideoViewController(runtime: runtime, post: post), animated: !UIAccessibility.isReduceMotionEnabled); return }
        let preview = MomentsPhotoViewController(runtime: runtime, post: post, index: index)
        preview.didClose = { [weak self] in
            guard let self else { return }
            let source = feedView.list.visibleCells.first { $0.accessibilityIdentifier == "moment.row." + post.id }
            UIAccessibility.post(notification: .screenChanged, argument: source ?? feedView.list)
        }
        present(preview, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
