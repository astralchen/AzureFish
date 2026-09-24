//
//  ComposerModel.swift
//  Demo
//

import Foundation

/// ``ComposerView`` 使用的本地化字符串。
nonisolated struct ComposerStrings: Equatable, Sendable {
    /// 空文本草稿显示的占位文字。
    let placeholder: String
    /// 发送按钮的本地化辅助功能标签。
    let send: String
    /// 附件菜单入口的本地化标签。
    let addAttachment: String
    /// 音频录制菜单项的本地化标题。
    let audio: String
    /// 开始听写操作的本地化标签。
    let dictate: String
    /// 停止听写操作的本地化标签。
    let stopDictation: String
    /// 停止录音操作的本地化标签。
    let stopRecording: String
    /// 取消音频草稿操作的本地化标签。
    let cancelAudio: String
    /// 播放音频操作的本地化标签。
    let playAudio: String
    /// 暂停音频操作的本地化标签。
    let pauseAudio: String
    /// 草稿非空、无法开始录音时显示的提示文字。
    let recordingRequiresEmptyDraft: String
    /// 文件选择菜单项的本地化标题；默认值为 `Files`。
    var file: String = "Files"
    /// 链接插入菜单项的本地化标题；默认值为 `Link`。
    var link: String = "Link"
    /// 已选照片或视频时，空注释输入区域显示的占位文字。
    var mediaPlaceholder: String = "Add a comment or send"
}

/// 输入栏当前可以请求的附件类型。
///
/// 菜单只能展示已经接入完整选择、预览、发送和清理流程的类型，并由
/// ViewController 选择对应协调器；Composer 不直接呈现
/// `PHPickerViewController`、播放器或相机界面。
nonisolated enum AttachmentKind: Equatable, Sendable {
    /// 从照片图库选择图片或视频。
    case photo
    /// 录制音频附件。
    case audio
    /// 从系统文件选择器导入文件。
    case file
    /// 输入网页 URL 并创建链接附件。
    case link
}

/// 按 TextKit 文档位置排列的语义片段，供发送与草稿持久化共用，不携带文件所有权。
///
/// 附件只编码稳定身份，其元数据由快照另行保存；编辑器生成的排版分隔字符不进入片段。
nonisolated enum DraftSegment: Codable, Equatable, Sendable {
    /// 编辑器中保留原始空格与换行的文字段。
    case text(String)
    /// 保留原始空格、换行及局部文字格式的正文段。
    case richText(MessageText)
    /// 按稳定标识符引用的内联附件段。
    case attachment(UUID)
}

/// 一次编辑事务中的正文和附件占位，顺序与用户插入内容一致。
nonisolated enum EditorInsertion {
    /// 在当前选区插入的纯文本内容。
    case text(String)
    /// 在当前选区插入的文档附件草稿。
    case attachment(DocumentDraft)
}

/// 用户从消息输入栏发起的操作。
///
/// 单一动作入口防止每增加一种附件就继续增加多组可选闭包。返回值只表示动作是否
/// 被业务层接受；文本仅在 `.sendText` 返回 `true` 后清空，附件草稿也只在发送
/// 成功后由其所有者提交。
nonisolated enum ComposerAction: Equatable, Sendable {
    /// 按编辑器顺序发送文字段与文档附件引用。
    case sendDocuments([DraftSegment])
    /// 删除指定稳定身份的文档草稿。
    case removeDocument(UUID)
    /// 打开指定稳定身份的文档草稿预览。
    case openDocument(UUID)
    /// 将有效网页 URL 插入为链接草稿。
    case insertLink(URL)
    /// 发送指定文本草稿。
    case sendText(String)
    /// 发送当前媒体组草稿及附带的文本。
    case sendMediaDraft(String)
    /// 从媒体草稿中删除指定项目。
    case removeMediaDraftItem(UUID)
    /// 请求预览已就绪的照片草稿。
    case openMediaDraftItem(UUID)
    /// 请求显示指定种类的附件输入入口。
    case requestAttachment(kind: AttachmentKind)
    /// 停止当前录音并保留有效音频供预览。
    case stopAudioRecording
    /// 取消当前附件草稿。
    case cancelAttachmentDraft
    /// 发送当前音频附件草稿。
    case sendAttachmentDraft
    /// 切换音频草稿的播放与暂停状态。
    case toggleAudioPreviewPlayback
    /// 请求开始麦克风听写。
    case startDictation
    /// 请求结束当前听写。
    case stopDictation
    /// 报告听写期间发生的手动编辑，使上层停止覆盖文本。
    case manualEditDuringDictation
}

/// 消息输入栏渲染的互斥展示状态。
///
/// 状态只包含 View 所需的值类型数据，不持有录音器、播放器或语音识别任务。
/// 媒体预览只传递值类型草稿，不把资源选择器或播放器对象放入输入栏状态。
nonisolated enum ComposerState: Equatable, Sendable {
    /// 没有活动录音或听写的常规文本编辑状态。
    case idle
    /// 正在请求权限或准备语音识别资源。
    case preparingSpeech
    /// 正在听写，并携带当前累计识别文本。
    case dictating(text: String)
    /// 正在录音，并携带已录制秒数与归一化波形。
    case recording(elapsed: TimeInterval, waveform: [Float])
    /// 预览已录制音频，并携带播放状态与 `0...1` 范围的进度。
    case audioPreview(
        attachment: AudioAttachment,
        isPlaying: Bool,
        progress: Double
    )
}
