import AzureFishAPI

/// 动态内容上报的用户意图；导航与业务写入由页面协调。
enum MomentsAction {
    case author, expand, like, comment, delete
    case reply(MomentsComment)
    case deleteComment(MomentsComment)
    case photo(Int)

    var comment: MomentsComment? {
        switch self {
        case .reply(let value), .deleteComment(let value): value
        default: nil
        }
    }
}

/// 发布组件的输入与媒体操作，不携带 UIKit 对象。
enum MomentsComposerAction {
    case textChanged(String)
    case moveImage(Int, to: Int)
    case removeImage(Int)
    case removeVideo
    case chooseMedia, editVideo, playVideo, publish, close
}
