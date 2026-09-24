//
//  ChatViewController.swift
//  Demo
//

import Combine
import AppLocalization
import OSLog
import QuickLayout
import QuickLayoutKit
import UIKit
import QuickLook

/// 支持文本、录制音频和语音转写草稿的一对一聊天 Demo。
@available(iOS 26.0, *)
final class ChatViewController: LocalizedQuickLayoutHostingController, MediaImageLoadingOwner {

    private static let logger = Logger(subsystem: "AzureFish.Chat", category: "ChatViewController")

    /// 页面全部媒体导入与图片显示共享的服务。
    let mediaImageLoader = MediaImageLoader()
    #if MEDIA_BENCHMARK
    /// 专用性能构建的页面测试驱动；正常构建不包含测试入口。
    private var mediaBenchmark: MediaConcurrencyBenchmark?
    #endif

    /// 异步文件分类任务及当前预览来源，拒绝过期展示请求。
    var attachmentPreviewTask: Task<Void, Never>?
    #if DEBUG
    /// 页面退出时取消测试资源导入，迟到结果不得插入已清理的会话。
    private var resourceFixtureTask: Task<Void, Never>?
    #endif
    /// 只有正常页面入口加载完整历史；注入依赖的测试入口从空会话开始。
    private var loadsInitialHistory = false
    var attachmentPreviewGeneration = 0
    weak var attachmentPreviewController: UIViewController?
    var attachmentPreviewSource: AttachmentPreviewRequest.Source?

    /// 聊天演示页面标题使用的本地化资源键。
    override var localizedTitleKey: String? { "demo.imessage.title" }

    /// 保存消息并生成时间线展示状态的视图模型。
    let viewModel: ChatViewModel
    /// 呈现消息时间线和单元格交互的会话视图。
    let conversationView = ConversationView()
    #if DEBUG
    /// 仅在页面几何变化时打印，避免每次布局回调重复输出同一组尺寸。
    private var debugLastViewportGeometry: String?
    #endif
    /// 承载文本、听写和附件草稿输入的视图。
    let composerView = ComposerView()
    /// 导航栏中显示联系人头像和副标题的视图。
    let contactTitleView = ContactTitleView(frame: .zero)
    /// 协调页面录音、音频播放和实时听写的控制器。
    let audioController: AudioController
    /// 负责内联文件、链接及混合粘贴草稿的控制器。
    let documentController: DocumentController
    /// 负责照片面板展示和媒体组导入的控制器。
    let photoController: PhotoPickerController
    /// 由页面所有附件功能共享的文件存储。
    let attachmentStore: any AttachmentStoring

    /// 当前聊天的稳定草稿标识；Demo 默认使用 `demo.chat`，可通过初始化参数隔离其他会话。
    var conversationID = "demo.chat"
    /// 可注入的草稿存储；`nil` 表示本页面不读取或保存持久化草稿。
    var draftStore: (any ChatDraftStoring)?
    /// 负责快照去重、防抖提交及文件租约的协调器；启用持久化后创建。
    var draftCoordinator: ChatDraftCoordinator?
    /// 当前批量恢复任务，结束后置为 `nil`，供生命周期测试等待恢复完成。
    var draftRestoreTask: Task<Void, Never>?
    /// 是否正在恢复草稿；此期间禁止输入及自动保存中间状态。
    var isRestoringDraft = false
    /// 是否正在执行可能触发多个控制器回调的输入栏动作，用于合并为最终内容变更。
    var isHandlingDraftAction = false
    /// 等待页面可展示时消费的本地化草稿错误键；没有待提示错误时为 `nil`。
    var pendingDraftNotice: String?

    /// 识别已提交音频文件的服务，与输入栏实时听写分开运行。
    private var audioFileTranscriber: any AudioFileTranscribing = AudioFileTranscriber()

    /// 文件转写独立于录音/播放；异步启动保证发送调用栈先完成附件提交。
    lazy var audioTranscription = AudioTranscriptionCoordinator(
        transcriber: audioFileTranscriber
    ) { [weak self] messageID, attachmentID, text in
        self?.viewModel.updateAudioTranscript(text, messageID: messageID, attachmentID: attachmentID)
    }

    /// 提供系统键盘可见性、几何和动画上下文的观察对象。
    let keyboardObserver = QuickLayoutKeyboardObserver()
    /// 页面持有的 Combine 订阅，释放时自动取消。
    var cancellables: Set<AnyCancellable> = []
    /// 当前输入栏需要避让的底部内容遮挡高度，单位为点。
    var bottomObstruction: CGFloat = 0
    /// 模态菜单暂时接管焦点时，保存编辑器的目标选区。
    var documentMenuSelection: NSRange?
    /// 以页面视图为坐标基准协调键盘与照片面板交接的对象。
    lazy var bottomObstructionCoordinator =
        BottomObstructionCoordinator(hostView: view)

    /// 创建共享同一附件目录、使用系统媒体协作者的聊天页面。
    convenience init() {
        let attachmentStore = PageAttachmentStore()
        let audioController = AudioController(
            attachmentStore: attachmentStore
        )
        self.init(
            viewModel: ChatViewModel(
                replyAudioSynthesizer: audioController
            ),
            audioController: audioController,
            attachmentStore: attachmentStore
        )
        loadsInitialHistory = SampleChatHistory.isEnabled(arguments: ProcessInfo.processInfo.arguments)
        // 注入入口和 XCTest 宿主默认不访问用户草稿；草稿 UI 测试显式选择独立会话。
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-chat-draft-session"), arguments.indices.contains(index + 1) {
            conversationID = arguments[index + 1]
            draftStore = ChatDraftStore.shared
        } else if loadsInitialHistory, NSClassFromString("XCTestCase") == nil,
                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            draftStore = ChatDraftStore.shared
        }
    }

    /// 使用指定的视图模型和真实媒体控制器创建聊天视图控制器。
    ///
    /// - Parameter viewModel: 管理消息时间线的视图模型。
    convenience init(viewModel: ChatViewModel) {
        let attachmentStore = PageAttachmentStore()
        self.init(
            viewModel: viewModel,
            audioController: AudioController(
                attachmentStore: attachmentStore
            ),
            attachmentStore: attachmentStore
        )
    }

    /// 使用可注入的时间线和媒体协作者创建聊天视图控制器。
    ///
    /// - Parameters:
    ///   - viewModel: 管理消息时间线的视图模型。
    ///   - audioController: 管理页面音频操作的控制器。
    ///   - audioFileTranscriber: 已提交语音的转写服务；`nil` 使用默认服务，与输入栏实时听写分离。
    ///   - conversationID: 草稿隔离标识，默认为 `demo.chat`。
    ///   - draftStore: 持久化草稿的存储；默认为 `nil`，注入后启用自动保存与恢复。
    init(
        viewModel: ChatViewModel,
        audioController: AudioController,
        audioFileTranscriber: (any AudioFileTranscribing)? = nil,
        conversationID: String = "demo.chat",
        draftStore: (any ChatDraftStoring)? = nil
    ) {
        self.conversationID = conversationID
        self.draftStore = draftStore
        let attachmentStore = audioController.attachmentStore
        self.viewModel = viewModel
        self.audioFileTranscriber = audioFileTranscriber ?? AudioFileTranscriber()
        self.audioController = audioController
        self.attachmentStore = attachmentStore
        documentController = DocumentController(store: attachmentStore, imageLoader: mediaImageLoader)
        photoController = PhotoPickerController(
            attachmentStore: attachmentStore, imageLoader: mediaImageLoader
        )
        super.init(nibName: nil, bundle: nil)
        (attachmentStore as? PageAttachmentStore)?.imageLoader = mediaImageLoader
    }

    /// 使用指定消息模型、音频控制器和附件存储组装页面依赖。
    ///
    /// - Parameters:
    ///   - viewModel: 管理消息时间线的视图模型。
    ///   - audioController: 管理页面录音、听写及播放的控制器。
    ///   - attachmentStore: 页面附件存储，应与音频控制器的存储共享文件所有权。
    ///   - conversationID: 草稿隔离标识，默认为 `demo.chat`。
    ///   - draftStore: 可注入的草稿存储；默认为 `nil`，不启用持久化。
    init(
        viewModel: ChatViewModel,
        audioController: AudioController,
        attachmentStore: any AttachmentStoring,
        conversationID: String = "demo.chat",
        draftStore: (any ChatDraftStoring)? = nil
    ) {
        self.conversationID = conversationID
        self.draftStore = draftStore
        self.viewModel = viewModel
        self.audioController = audioController
        self.attachmentStore = attachmentStore
        documentController = DocumentController(store: attachmentStore, imageLoader: mediaImageLoader)
        photoController = PhotoPickerController(
            attachmentStore: attachmentStore, imageLoader: mediaImageLoader
        )
        super.init(nibName: nil, bundle: nil)
        (attachmentStore as? PageAttachmentStore)?.imageLoader = mediaImageLoader
    }

    /// 不支持从归档创建 `ChatViewController`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        let audioController = AudioController()
        self.audioController = audioController
        let attachmentStore = audioController.attachmentStore
        self.attachmentStore = attachmentStore
        documentController = DocumentController(store: attachmentStore, imageLoader: mediaImageLoader)
        photoController = PhotoPickerController(
            attachmentStore: attachmentStore, imageLoader: mediaImageLoader
        )
        viewModel = ChatViewModel(
            replyAudioSynthesizer: audioController
        )
        super.init(coder: coder)
        (attachmentStore as? PageAttachmentStore)?.imageLoader = mediaImageLoader
        loadsInitialHistory = SampleChatHistory.isEnabled(arguments: ProcessInfo.processInfo.arguments)
    }

    /// 页面释放时使历史请求失效，并回收正常入口拥有的附件目录。
    isolated deinit {
        viewModel.cancelHistory()
        // 正常入口独占页面目录；外部保留 ViewModel 时也不能延长附件文件生命周期。
        if loadsInitialHistory { attachmentStore.removeAll() }
    }

    /// 为正常入口配置样例来源并请求首页；依赖注入和 fixture 入口保持关闭。
    ///
    /// 来源与页面共享附件目录，并使用模型时钟作为所有分页消息的固定时间基准。
    private func loadInitialHistory() {
        guard loadsInitialHistory else { return }
        viewModel.configureHistory(source: SampleHistoryLoader(
            store: attachmentStore, localizer: viewModel.localizer, referenceDate: viewModel.clock()))
        viewModel.loadHistory()
    }

    /// 定义 `ChatViewController` 的布局层级、间距和对齐方式。
    override var body: Layout {
        ZStack(alignment: .bottom) {
            conversationView
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composerView
                .resizable(axis: .horizontal)
                .fixedSize(axis: .vertical)
                .padding(.bottom, bottomObstruction)
                .safeAreaPadding([.horizontal, .bottom], 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 配置导航标题、保存状态与交互绑定，并开始观察消息和底部遮挡变化。
    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
        super.viewDidLoad()

        contactTitleView.sizeToFit()
        navigationItem.titleView = contactTitleView
        setContentScrollView(conversationView.collectionView, for: .top)
        conversationView.viewportDidLayout = { [weak self] in self?.updateConversationViewport() }
        composerView.geometryDidLayout = { [weak self] in self?.updateConversationViewport() }
        view.backgroundColor = .systemBackground
        conversationView.attachmentSaveState = { [weak self] key in
            self?.attachmentSaveCoordinator.state(for: key) ?? .available
        }
        attachmentSaveCoordinator.stateDidChange = { [weak self] key, state in
            self?.conversationView.updateSaveState(state, for: key)
            if state == .completed {
                UIAccessibility.post(notification: .announcement, argument: Localization.text("imessage.save.completed"))
            }
        }
        attachmentSaveCoordinator.failed = { [weak self] error in self?.presentAttachmentSaveFailure(error) }
        conversationView.openMenuAttachment = { [weak self] in self?.openMenuAttachment($0) }
        conversationView.menuSaveState = { [weak self] in self?.menuSaveCoordinator.state(for: $0) ?? .available }
        menuSaveCoordinator.failed = { [weak self] in self?.presentAttachmentSaveFailure($0) }
        menuSaveCoordinator.changed = { [weak self] in self?.conversationView.refreshMenuAccessibility() }
        conversationView.loadEarlierHistory = { [weak self] in self?.viewModel.loadHistory() }
        conversationView.retryHistory = { [weak self] in self?.viewModel.loadHistory(retrying: true) }
        configureInteractions()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-imessage-menu-long-text") {
            viewModel.insertInitialHistory([.init(direction: .outgoing, content: .userText(
                String(repeating: "Long message keeps its original bubble. 长按保留原消息气泡与排版。\n", count: 12)))])
        } else if arguments.contains("-imessage-menu-fixture") {
            viewModel.insertInitialHistory([
                .init(direction: .incoming, content: .userText("Menu text https://www.apple.com")),
                .init(direction: .outgoing, content: .richText(.init(runs: [.init("Bold menu text", style: .bold)])))
            ])
        }
        if arguments.contains("-imessage-menu-web") {
            let url = URL(string: "https://www.apple.com")!
            viewModel.appendSavePreviewAttachment(.link(.init(url: url, title: "Apple")))
        }
        if let index = arguments.firstIndex(of: "-imessage-save-fixture"),
           arguments.indices.contains(index + 1),
           ["resources", "resources-video", "resources-pdf", "resources-heic", "resources-draft", "resources-live", "resources-live-single", "resources-live-audio"].contains(arguments[index + 1]) {
            resourceFixtureTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let fixture = try await AttachmentSavePreviewFixtures.resourceAttachment(
                        named: arguments[index + 1], store: attachmentStore)
                    guard !Task.isCancelled, !hasCleanedUpChat else { return }
                    if arguments.contains("-imessage-preview-draft") {
                        if case .mediaGroup(let group) = fixture { photoController.applyPreviewFixture(group) }
                        else if case .file(let file) = fixture { documentController.importDocument(file.fileURL) }
                    } else { viewModel.appendSavePreviewAttachment(fixture) }
                } catch is CancellationError {
                    // 页面退出属于正常取消，导入器负责回收部分文件。
                } catch {
                    if ChatDiagnostics.isEnabled {
                        Self.logger.error("[AttachmentPreviewFixture] import failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
        if let fixture = try? AttachmentSavePreviewFixtures.attachment(store: attachmentStore) {
            if ProcessInfo.processInfo.arguments.contains("-imessage-preview-draft") {
                if case .mediaGroup(let group) = fixture { photoController.applyPreviewFixture(group) }
                else if case .file(let file) = fixture { documentController.importDocument(file.fileURL) }
            } else {
                viewModel.appendSavePreviewAttachment(fixture,
                    direction: arguments.contains("-imessage-menu-audio-outgoing") ? .outgoing : .incoming)
            }
        }
        let previewVideoFile = ProcessInfo.processInfo.arguments.contains("preview-video-file")
        if ProcessInfo.processInfo.arguments.contains("preview-video") || previewVideoFile {
            Task { [weak self] in
                guard let self, let fixture = try? await AttachmentSavePreviewFixtures.videoAttachment(
                    store: attachmentStore, transform: previewVideoFile ? CGAffineTransform(rotationAngle: .pi / 2) : .identity),
                    !hasCleanedUpChat else { return }
                if previewVideoFile, let item = fixture.mediaGroup?.items.first {
                    viewModel.appendSavePreviewAttachment(.file(.init(id: UUID(), fileURL: item.originalFileURL,
                        displayName: "Portrait.mov", typeIdentifier: "com.apple.quicktime-movie", byteCount: 0)))
                } else { viewModel.appendSavePreviewAttachment(fixture) }
            }
        }
        #endif
        if loadsInitialHistory {
            conversationView.initialPresentation.waitForHistory(in: conversationView)
        }
        bindViewModel()
        configureDraftPersistence()
        loadInitialHistory()
        observeKeyboard()
        configureBottomObstruction()
        #if MEDIA_BENCHMARK
        if ProcessInfo.processInfo.arguments.contains("-media-benchmark") {
            mediaBenchmark = MediaConcurrencyBenchmark(chat: self)
            mediaBenchmark?.install()
        }
        #endif
    }

    /// 在页面布局完成后重新采样键盘与照片面板的遮挡几何。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bottomObstructionCoordinator.refreshGeometry()
        updateConversationViewport()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        conversationView.debugLogScroll("page.transition", detail: "targetSize=\(size)")
        conversationView.prepareForViewportChange()
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewSafeAreaInsetsDidChange() {
        conversationView.debugLogScroll("page.safeAreaChanged", detail: "pageSafe=\(view.safeAreaInsets)")
        conversationView.prepareForViewportChange()
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    /// 输入栏的实际顶部是列表可见区域的底边；键盘只移动输入栏，不缩小列表。
    func updateConversationViewport() {
        let list = conversationView.collectionView
        guard list.superview != nil, composerView.superview != nil,
              list.bounds.height > 0, composerView.bounds.height > 0 else { return }
        let listFrame = list.convert(list.bounds, to: view)
        let composerFrame = composerView.convert(composerView.bounds, to: view)
        #if DEBUG
        let geometry = "page=\(view.bounds) list=\(listFrame) composer=\(composerFrame) pageSafe=\(view.safeAreaInsets) obstruction=\(bottomObstruction)"
        if debugLastViewportGeometry != geometry {
            debugLastViewportGeometry = geometry
            conversationView.debugLogScroll("page.geometry", detail: geometry)
        }
        #endif
        // QuickLayout 分步更新子视图；宽窄切换时不能混用旧列表尺寸与新的页面安全区。
        // 等列表和输入栏都到达本次布局位置后再消费已捕获的阅读锚点。
        guard abs(listFrame.width - view.bounds.width) < 0.5,
              abs(listFrame.height - view.bounds.height) < 0.5,
              abs(composerFrame.maxY - (view.bounds.maxY - view.safeAreaInsets.bottom - bottomObstruction)) < 0.5 else {
            return
        }
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        conversationView.updateViewportInsets(UIEdgeInsets(
            top: max(0, safeFrame.minY - listFrame.minY),
            left: max(0, safeFrame.minX - listFrame.minX),
            bottom: max(0, listFrame.maxY - composerFrame.minY),
            right: max(0, listFrame.maxX - safeFrame.maxX)
        ))
    }

    /// 高度与遮挡变化共用一个布局事务，避免独立回调重复滚动。
    func layoutChatContent() {
        quickLayoutIfNeeded()
        updateConversationViewport()
    }

    /// 管理附件保存操作、状态反馈和页面退出失效的协调器。
    let attachmentSaveCoordinator = AttachmentSaveCoordinator()
    let menuSaveCoordinator = MessageMenuSaveCoordinator()
    /// 指示页面或其父容器正在退出聊天层级的布尔值。
    private var isLeavingChat = false
    /// 指示页面退出清理已经执行的布尔值，防止重复取消和删除资源。
    var hasCleanedUpChat = false

    /// 在页面即将出现时重置退出标记，使取消返回手势后仍可继续使用。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isLeavingChat = false
    }

    /// 页面完成显示后尝试展示恢复错误或此前保存失败的提示。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingDraftNotice()
    }

    /// 停止当前音频播放，并沿父控制器层级判断是否正在退出聊天。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        audioController.stopPlayback()
        // 同时覆盖聊天页自身退出和导航/Tab 等父容器被关闭。
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if controller.isMovingFromParent || controller.isBeingDismissed {
                isLeavingChat = true
                conversationView.invalidateMessageMenu()
                break
            }
            ancestor = controller.parent
        }
    }

    /// 在页面确实退出且转场未取消时统一清理任务、草稿、面板与附件目录。
    ///
    /// 临时被其他界面覆盖不触发整页资源清理。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 临时覆盖只停播放；交互式返回取消后仍需要这些附件和页面任务。
        guard isLeavingChat, transitionCoordinator?.isCancelled != true,
              !hasCleanedUpChat else { return }
        // 先冻结快照并取得文件租约，再关闭回调和清理页面，防止复制源被提前删除。
        flushDraftBeforeLeaving()
        hasCleanedUpChat = true
        viewModel.cancelHistory()
        #if MEDIA_BENCHMARK
        mediaBenchmark?.cancel()
        mediaBenchmark = nil
        #endif
        #if DEBUG
        resourceFixtureTask?.cancel()
        resourceFixtureTask = nil
        #endif
        attachmentPreviewTask?.cancel()
        attachmentPreviewGeneration += 1
        let activePreview = attachmentPreviewController
        (activePreview as? AttachmentPreviewController)?.completeDismissal()
        activePreview?.dismiss(animated: false)
        attachmentSaveCoordinator.invalidate()
        conversationView.invalidateMessageMenu()
        menuSaveCoordinator.invalidate()
        composerView.dismissRecordingUnavailableHint()
        composerView.pasteCoordinator.invalidate()
        audioTranscription.cancelAll()
        viewModel.cancelPendingReply()
        audioController.stopAll()
        audioController.cancelRecordingOrPreview()
        photoController.dismissPicker(animated: false)
        photoController.discardDraft()
        documentController.discardAll()
        bottomObstructionCoordinator.stop()
        mediaImageLoader.cancelAll()
        mediaImageLoader.clearCache()
        attachmentStore.removeAll()
    }

    /// 刷新联系人、输入栏、媒体动作和时间线使用的本地化内容。
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        contactTitleView.configure(
            subtitle: Localization.text("imessage.contact.subtitle")
        )
        contactTitleView.sizeToFit()
        let mediaStrings = makeMediaStrings()
        composerView.configure(
            strings: ComposerStrings(
                placeholder: Localization.text(
                    "imessage.composer.placeholder"
                ),
                send: Localization.text("imessage.composer.send"),
                addAttachment: Localization.text(
                    "imessage.attachment.add"
                ),
                audio: Localization.text("imessage.attachment.audio"),
                dictate: Localization.text("imessage.dictation.start"),
                stopDictation: Localization.text(
                    "imessage.dictation.stop"
                ),
                stopRecording: Localization.text(
                    "imessage.audio.record.stop"
                ),
                cancelAudio: Localization.text(
                    "imessage.audio.cancel"
                ),
                playAudio: Localization.text("imessage.audio.play"),
                pauseAudio: Localization.text("imessage.audio.pause"),
                recordingRequiresEmptyDraft: Localization.text(
                    "imessage.audio.record.requiresEmptyDraft"
                ),
                file: Localization.text("imessage.attachment.file"),
                link: Localization.text("imessage.attachment.link"),
                mediaPlaceholder: Localization.text("imessage.composer.mediaPlaceholder")
            ),
            mediaStrings: mediaStrings
        )
        conversationView.configureMediaStrings(mediaStrings)
        viewModel.refreshLocalizedContent()
    }

    /// 将应用布局方向同步到输入栏、联系人标题和消息时间线。
    override func reloadLayoutDirection(
        _ direction: UIUserInterfaceLayoutDirection
    ) {
        super.reloadLayoutDirection(direction)
        let semanticAttribute = direction.appLayoutDirection
            .semanticContentAttribute
        contactTitleView.semanticContentAttribute = semanticAttribute
        composerView.applyLayoutDirection(direction)
        conversationView.applyLayoutDirection(direction)
        setNeedsQuickLayout()
    }
}

#if DEBUG
/// 创建使用固定时钟与示例依赖的完整聊天页面预览。
@available(iOS 26.0, *)
@MainActor
private func makeChatViewControllerPreview() -> UIViewController {
    let viewModel = ChatViewModel(
        localizer: .live,
        clock: { ConversationPreviewData.fixedDate },
        sleeper: { duration in
            try await Task.sleep(for: duration)
        }
    )
    return UINavigationController(
        rootViewController: ChatViewController(viewModel: viewModel)
    )
}

@available(iOS 26.0, *)
#Preview("iMessage 聊天页面") {
    makeChatViewControllerPreview()
}
#endif
