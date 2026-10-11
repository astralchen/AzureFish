import AzureFishAPI
import UIKit
import AzureFishMoments

/// 为展示组件提供账号媒体绑定；所有缓存、失权和停止规则仍由运行时管理。
@MainActor
final class MomentsMediaProvider {
    private let runtime: MomentsRuntime
    var userID: String { runtime.userID }

    init(runtime: MomentsRuntime) { self.runtime = runtime }

    func configure(_ avatar: AccountAvatarView, user: ChatUser) {
        if let session = runtime.session, let id = UUID(uuidString: user.id) {
            avatar.configure(session: session, user: id, asset: user.avatarID)
        } else { avatar.reset() }
    }

    func localImage(_ image: MomentsImageDraft) async throws -> Data {
        try await runtime.work { try await self.runtime.localImage(image) }
    }

    func bind(_ binding: MomentsImageBinding, to button: UIButton, asset: ChatAsset?, target: String, cover: Bool = false) {
        binding.configure(button, runtime: runtime, asset: asset, target: target, cover: cover)
    }
}
