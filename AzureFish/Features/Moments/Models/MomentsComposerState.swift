import Foundation
import AzureFishMoments

/// 发布草稿及控件可用性；草稿只由发布视图模型修改。
struct MomentsComposerState {
    var draft: MomentsDraft
    let isCover: Bool
    var busy = false
    var errorKey: String?
    var progress: Float = 0
    /// 媒体内容或顺序变化时递增，用于刷新缩略图而不随每次文本编辑重建。
    var mediaRevision: UInt64 = 0

    /// 已固定发布字节或封面资产时冻结编辑，避免未知提交结果被新内容覆盖。
    var frozen: Bool { draft.publication != nil || draft.coverAsset != nil }
    var canEdit: Bool { !busy && !frozen }
    var canAdd: Bool { canEdit && draft.video == nil && draft.images.count < (isCover ? 1 : 9) }
    var canPublish: Bool {
        !busy && (frozen || (isCover ? draft.images.count == 1 : !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.images.isEmpty || draft.video?.output != nil))
            && draft.text.count <= 2000 && (frozen || draft.video == nil || draft.video?.output != nil)
    }
}
