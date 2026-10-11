import AzureFishAPI

/// 动态流的只读展示快照；窗口尺寸和系统外观由列表视图独立处理。
struct MomentsFeedState: Equatable {
    let posts: [MomentsPost]
    let album: MomentsAlbum
    let expanded: Set<String>
    let busy: Set<String>
    let status: String?
    let loading: Bool
    let footer: MomentsPaginationState?
    let canCompose: Bool
}
