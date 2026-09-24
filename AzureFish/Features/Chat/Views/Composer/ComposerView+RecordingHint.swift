//
//  ComposerView+RecordingHint.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 管理录音不可用提示及其生命周期。
@available(iOS 26.0, *)
extension ComposerView {

    /// 检查录音入口；非空草稿只展示提示，不应继续请求权限或启动音频服务。
    ///
    /// 空格、换行以及正在导入的媒体也属于草稿。重复请求不会延长当前提示。
    /// - Returns: 只有空闲且输入栏完全为空时返回 `true`。
    func validateAudioRecordingRequest() -> Bool {
        guard composerState == .idle, !isShowingRecordingUnavailableHint else {
            return false
        }
        guard !(textView.text ?? "").isEmpty || mediaDraft != nil else {
            return true
        }
        retainedTextContentOffset = textView.contentOffset
        pasteCoordinator.invalidate()
        performPresentationUpdate { [self] in
            isShowingRecordingUnavailableHint = true
            refreshRecordingHintLayout()
        }
        recordingHintGeneration += 1
        let generation = recordingHintGeneration
        UIAccessibility.post(
            notification: .announcement,
            argument: strings.recordingRequiresEmptyDraft
        )
        let sleeper = recordingHintSleeper
        recordingHintTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await sleeper(.seconds(2))
            } catch {
                // 主动取消由调用方同步清理；等待失败也不能使输入栏永久禁用。
            }
            guard !Task.isCancelled, let self,
                  recordingHintGeneration == generation else { return }
            dismissRecordingUnavailableHint()
        }
        return false
    }

    /// 取消临时提示并按最新草稿恢复输入栏，保留用户当前的键盘选择。
    func dismissRecordingUnavailableHint() {
        recordingHintGeneration += 1
        recordingHintTask?.cancel()
        recordingHintTask = nil
        guard isShowingRecordingUnavailableHint else { return }
        performPresentationUpdate { [self] in
            isShowingRecordingUnavailableHint = false
            updateTextHeight()
            refreshRecordingHintLayout()
        }
    }

    /// 使用与媒体状态切换相同的高度通知，使页面继续遵守原有滚动规则。
    func refreshRecordingHintLayout() {
        updateComposerState()
        inputGlassView.setNeedsQuickLayout()
        editorContainer.setNeedsQuickLayout()
        setNeedsQuickLayout()
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        notifyHeightChange(.immediate)
    }
}
