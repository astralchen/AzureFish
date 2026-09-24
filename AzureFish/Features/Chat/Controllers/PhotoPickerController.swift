//
//  PhotoPickerController.swift
//  Demo
//

import AVFoundation
import ImageIO
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 管理系统照片选择面板、有序媒体草稿及页面文件导入的控制器。
@available(iOS 17.0, *)
@MainActor
final class PhotoPickerController: NSObject,
    PHPickerViewControllerDelegate,
    UISheetPresentationControllerDelegate {

    /// 持有单次媒体导入资源和进度的可变草稿条目。
    @MainActor
    final class DraftEntry {
        /// 导入占位与最终媒体项目共享的稳定标识符。
        let id: UUID
        /// 用于同步系统照片选中状态的资源标识符。
        let assetIdentifier: String?
        let initialDisplaySize: CGSize?
        let waitsForDisplaySize: Bool
        /// 条目当前的导入占位或已就绪媒体值。
        var content: MediaDraftItemContent = .importing
        /// 系统文件表示加载的可取消进度对象。
        var progress: Progress?
        /// 可取消的后台媒体处理任务。
        var task: Task<Void, Never>?
        /// 文件复制和取消竞争的单次状态机。
        var fileRequest: MediaFileRequest?
        var livePhotoRequest: LivePhotoImportRequest?
        /// 正在导入的媒体原件目标 URL。
        var originalURL: URL?
        /// 媒体缩略图的目标 URL。
        var thumbnailURL: URL?

        /// 创建带稳定身份和可选照片资源标识符的导入条目。
        init(id: UUID = UUID(), assetIdentifier: String?, initialDisplaySize: CGSize? = nil,
             waitsForDisplaySize: Bool = false) {
            self.id = id
            self.assetIdentifier = assetIdentifier
            self.initialDisplaySize = initialDisplaySize
            self.waitsForDisplaySize = waitsForDisplaySize
        }

        /// 供输入栏渲染使用、不持有系统进度对象的条目快照。
        var presentation: MediaDraftItemPresentation {
            MediaDraftItemPresentation(
                id: id,
                assetIdentifier: assetIdentifier,
                content: content,
                initialDisplaySize: initialDisplaySize,
                waitsForDisplaySize: waitsForDisplaySize
            )
        }
    }

    /// 与键盘内容高度对应的自定义照片面板档位标识符。
    private static let keyboardDetentIdentifier = UISheetPresentationController.Detent.Identifier(
        "imessage.photo.keyboard"
    )

    /// 负责页面媒体原件、缩略图及草稿登记的附件存储。
    let attachmentStore: any AttachmentStoring
    /// 媒体控制器初始化时注入并保留的文件管理器。
    private let fileManager: FileManager
    /// 导入和显示共用的页面图片服务。
    let imageLoader: MediaImageLoader
    /// 已登记占位但尚未启动的选择结果。
    struct PendingImport {
        /// 系统提供者及资源身份。
        let provider: NSItemProvider
        /// 可变草稿条目。
        let entry: DraftEntry
        /// 创建请求时的草稿代次。
        let generation: Int
    }
    /// 等待系统文件导入的有序队列。
    var pendingImports: [PendingImport] = []
    /// 尚未真正完成的导入；取消后也不能提前释放槽位。
    var activeImports: Set<UUID> = []

    /// 当前媒体草稿组的身份；提交或丢弃后重新生成。
    private var groupID = UUID()
    /// 按系统连续选择顺序排列的媒体导入条目。
    var entries: [DraftEntry] = []
    /// 当前系统照片选择器；关闭完成后解除持有。
    var picker: PHPickerViewController?
    /// 承载系统照片选择器、供外部采样面板几何的宿主。
    private var sheetHost: SheetHostController?
    /// 当前草稿版本；提交或丢弃后递增以拒绝旧导入结果。
    var generation = 0
    /// 用于计算照片小档高度的稳定键盘内容高度，默认值为 300 点。
    private var storedKeyboardHeight: CGFloat = 300

    /// 有序媒体草稿变化时调用的闭包；没有项目时传入 `nil`。
    var stateDidChange: ((MediaDraftPresentation?) -> Void)?
    /// 媒体导入失败并完成条目清理后调用的闭包。
    var failureDidOccur: (() -> Void)?
    #if MEDIA_BENCHMARK
    /// 性能构建在实际草稿发布后记录就绪时间，不改变生产观察者。
    var benchmarkDidPublish: (() -> Void)?
    #endif
    /// 开始展示面板前调用的闭包，使页面能够先跟踪面板并处理键盘交接。
    var pickerDidPresent: ((UIViewController) -> Void)?
    /// 系统入场动画完成时调用，用于解除键盘到照片面板的输入栏位置冻结。
    var pickerDidFinishPresenting: ((UIViewController) -> Void)?
    /// 面板关闭完成时调用的闭包。
    var pickerDidDismiss: (() -> Void)?

    /// 创建使用页面附件存储和指定文件管理器的照片控制器。
    init(
        attachmentStore: any AttachmentStoring,
        fileManager: FileManager = .default,
        imageLoader: MediaImageLoader? = nil
    ) {
        self.attachmentStore = attachmentStore
        self.fileManager = fileManager
        self.imageLoader = imageLoader ?? MediaImageLoader()
        super.init()
    }

    /// 恢复完整媒体条目及文件所有权，不重新请求照片库访问。
    ///
    /// 丢弃当前选择及未完成导入，按原顺序建立就绪条目，并发布恢复后的媒体草稿状态。
    /// - Parameter group: 原件、缩略图及 Live Photo 配对视频均已复制到页面目录的媒体组。
    func restoreDraft(_ group: MediaGroupAttachment) {
        discardDraft()
        groupID = group.id
        entries = group.items.map { item in
            let entry = DraftEntry(id: item.id, assetIdentifier: item.assetIdentifier)
            entry.content = .ready(item)
            entry.originalURL = item.originalFileURL
            entry.thumbnailURL = item.thumbnailFileURL
            return entry
        }
        registerReadyDraftIfPossible()
        publishDraft()
    }

    #if DEBUG
    /// 将本地样例安装为就绪媒体草稿，供界面测试绕过照片库选择与导入过程。
    ///
    /// - Parameter group: 已准备好本地资源的样例媒体组。
    func applyPreviewFixture(_ group: MediaGroupAttachment) { restoreDraft(group) }
    #endif

    /// 当前媒体草稿的有序展示快照；没有条目时为 `nil`。
    var draft: MediaDraftPresentation? {
        guard !entries.isEmpty else { return nil }
        return MediaDraftPresentation(
            groupID: groupID,
            items: entries.map(\.presentation)
        )
    }

    /// 当前可发送的媒体组；草稿为空或存在未完成导入时为 `nil`。
    var draftAttachment: MediaGroupAttachment? {
        draft?.attachment
    }

    /// 从创建面板到关闭动画完成均视为已展示，覆盖动画期间的键盘通知窗口。
    var isPresented: Bool {
        sheetHost != nil
    }

    /// 展示连续有序选择的照片面板，并以稳定键盘高度配置初始档位。
    ///
    /// 已经展示时仅将面板切回键盘高度档位。
    func present(
        from presenter: UIViewController,
        keyboardHeight: CGFloat
    ) {
        if keyboardHeight > 0 {
            storedKeyboardHeight = keyboardHeight
        }
        if let sheetHost {
            if sheetHost.presentingViewController != nil {
                sheetHost.sheetPresentationController?.animateChanges {
                    sheetHost.sheetPresentationController?.selectedDetentIdentifier = Self.keyboardDetentIdentifier
                }
            }
            return
        }

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = MediaGroupAttachment.selectionLimit
        configuration.selection = .continuousAndOrdered
        configuration.preferredAssetRepresentationMode = .current
        configuration.mode = .default
        // 隐藏顶部导航栏和底部工具栏，让面板只显示照片网格。
        configuration.edgesWithoutContentMargins = [.top, .bottom]
        configuration.disabledCapabilities = [
            // 选择结果已实时同步至 Composer，由其提供移除和发送入口。
            .selectionActions,
            .stagingArea,
            .sensitivityAnalysisIntervention,
        ]
        configuration.preselectedAssetIdentifiers = entries.compactMap(\.assetIdentifier)

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        let sheetHost = SheetHostController(picker: picker)
        sheetHost.modalPresentationStyle = .pageSheet
        if let sheet = sheetHost.sheetPresentationController {
            configureDetents(of: sheet)
            sheet.selectedDetentIdentifier = Self.keyboardDetentIdentifier
            sheet.largestUndimmedDetentIdentifier = Self.keyboardDetentIdentifier
            // 拖动条叠加在照片网格上，不单独占用顶部高度。
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.delegate = self
        }
        self.picker = picker
        self.sheetHost = sheetHost
        // 顺序不可交换：先让协调器接管遮挡并冻结高度上限，再收键盘、展示面板。
        // 附件菜单关闭可能同步发出较小的键盘高度，若尚未接管就会污染本次上限。
        pickerDidPresent?(sheetHost)
        presenter.view.endEditing(true)
        presenter.present(sheetHost, animated: true) { [weak self] in
            self?.pickerDidFinishPresenting?(sheetHost)
        }
    }

    /// 关闭照片面板，并在动画完成前保留宿主引用供页面跟踪几何。
    ///
    /// - Parameters:
    ///   - animated: 是否使用系统关闭动画。
    ///   - completion: 面板关闭及引用清理完成后调用的闭包。
    func dismissPicker(animated: Bool, completion: (() -> Void)? = nil) {
        guard let sheetHost, sheetHost.presentingViewController != nil else {
            completion?()
            return
        }
        sheetHost.dismiss(animated: animated) { [weak self] in
            // 动画完成前保留面板引用，供协调器逐帧读取位置，避免关闭开始时直接落底。
            self?.finishDismissing(sheetHost)
            completion?()
        }
    }

    /// 保存下一次照片小档使用的稳定键盘内容高度。
    ///
    /// 照片 Sheet 与键盘交接时只更新缓存，不重新计算正在 dismiss 的 Sheet；普通
    /// 键盘高度变化则允许调用方同步刷新已经展示的 detent。
    func updateKeyboardHeight(
        _ height: CGFloat,
        invalidatingPresentedDetent: Bool = true
    ) {
        guard height > 0 else { return }
        storedKeyboardHeight = height
        guard invalidatingPresentedDetent else { return }
        guard let sheet = sheetHost?.sheetPresentationController else { return }
        configureDetents(of: sheet)
        sheet.invalidateDetents()
    }

    /// 取消并删除指定草稿项目，同步系统选择状态后发布剩余草稿。
    func removeItem(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        cancelImport(entry)
        if let assetIdentifier = entry.assetIdentifier {
            picker?.deselectAssets(withIdentifiers: [assetIdentifier])
        }
        registerReadyDraftIfPossible()
        publishDraft()
    }

    /// 将全部就绪的媒体草稿转为已提交附件，清除系统勾选并保留面板当前档位。
    ///
    /// - Returns: 有可发送媒体组且完成提交时为 `true`；否则为 `false`。
    @discardableResult
    func commitDraft() -> Bool {
        guard let attachment = draftAttachment else { return false }
        if !attachmentStore.commitDraft(id: attachment.id) {
            attachmentStore.registerCommitted(.mediaGroup(attachment))
        }
        let selectedIdentifiers = entries.compactMap(\.assetIdentifier)
        entries.removeAll()
        groupID = UUID()
        generation &+= 1
        // 先清空草稿并推进版本，再同步系统选择，避免同步回调复用已提交的条目。
        if !selectedIdentifiers.isEmpty {
            picker?.deselectAssets(withIdentifiers: selectedIdentifiers)
        }
        publishDraft()
        return true
    }

    /// 取消全部导入，删除未提交文件并使当前草稿版本失效。
    func discardDraft() {
        entries.forEach(cancelImport)
        pendingImports.removeAll()
        if let draftAttachment { attachmentStore.discardDraft(id: draftAttachment.id) }
        entries.removeAll()
        groupID = UUID()
        generation &+= 1
        publishDraft()
    }

    /// 连续选择返回当前完整选择；空数组表示最后一项也已取消勾选。
    func picker(
        _ picker: PHPickerViewController,
        didFinishPicking results: [PHPickerResult]
    ) {
        // 关闭或替换过的面板不得回写当前草稿。
        guard self.picker === picker else { return }
        apply(results)
    }

    /// 将系统面板关闭事件转发给页面协调层。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishDismissing(presentationController.presentedViewController)
    }

    /// 系统手势和主动关闭共用收尾；取消手势不进入这里，旧面板也不能清理新面板。
    private func finishDismissing(_ dismissedHost: UIViewController) {
        guard sheetHost === dismissedHost else { return }
        picker = nil
        sheetHost = nil
        // 先清理再通知，允许观察者在回调中重新打开面板。
        pickerDidDismiss?()
    }

    /// 按新选择顺序复用已有资源条目，导入新增项目并删除不再选择的文件。
    private func apply(_ results: [PHPickerResult]) {
        let currentGeneration = generation
        let previousByIdentifier = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                entry.assetIdentifier.map { ($0, entry) }
            }
        )
        var nextEntries: [DraftEntry] = []
        var retainedIDs: Set<UUID> = []
        // 选中时就批量读取资源元数据，不等待原件复制或缩略图生成。
        let selectedSizes = Self.selectedAssetSizes(for: results.prefix(MediaGroupAttachment.selectionLimit)
            .compactMap(\.assetIdentifier).filter { previousByIdentifier[$0] == nil })

        for result in results.prefix(MediaGroupAttachment.selectionLimit) {
            if let identifier = result.assetIdentifier,
               let existing = previousByIdentifier[identifier] {
                nextEntries.append(existing)
                retainedIDs.insert(existing.id)
                continue
            }
            let initialSize = result.assetIdentifier.flatMap { selectedSizes[$0] }
                ?? Self.validDisplaySize(result.itemProvider.preferredPresentationSize)
            let entry = DraftEntry(assetIdentifier: result.assetIdentifier, initialDisplaySize: initialSize,
                                   waitsForDisplaySize: true)
            nextEntries.append(entry)
            retainedIDs.insert(entry.id)
            pendingImports.append(PendingImport(provider: result.itemProvider, entry: entry, generation: currentGeneration))
        }

        for entry in entries where !retainedIDs.contains(entry.id) {
            cancelImport(entry)
        }
        entries = nextEntries
        drainImports()
        registerReadyDraftIfPossible()
        publishDraft()
    }

    private static func selectedAssetSizes(for identifiers: [String]) -> [String: CGSize] {
        guard !identifiers.isEmpty else { return [:] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [:] }
        var sizes: [String: CGSize] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            if let size = validDisplaySize(CGSize(width: asset.pixelWidth, height: asset.pixelHeight)) {
                sizes[asset.localIdentifier] = size
            }
        }
        return sizes
    }

    static func validDisplaySize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// 向观察者发布当前有序草稿快照。
    func publishDraft() {
        stateDidChange?(draft)
        #if MEDIA_BENCHMARK
        benchmarkDidPublish?()
        #endif
    }

    /// 控制器释放时停止所有请求；回调仍会清理未交付文件。
    isolated deinit {
        entries.forEach { $0.fileRequest?.cancel(); $0.livePhotoRequest?.cancel(); $0.task?.cancel() }
    }

    /// 设置不低于 220 点的键盘高度档位及系统大档位。
    private func configureDetents(of sheet: UISheetPresentationController) {
        let height = max(220, storedKeyboardHeight)
        let keyboardDetent = UISheetPresentationController.Detent.custom(
            identifier: Self.keyboardDetentIdentifier
        ) { _ in height }
        sheet.detents = [keyboardDetent, .large()]
    }
}
