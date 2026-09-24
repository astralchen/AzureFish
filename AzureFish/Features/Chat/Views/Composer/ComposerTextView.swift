//
//  ComposerTextView.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 在临时提示期间冻结键盘和输入法修改，同时保留第一响应者与组合文本。
final class ComposerTextView: UITextView {
    /// 只拦截编辑，不修改 `isEditable` 或第一响应者状态。
    var isInputSuspended = false
    /// 允许粘贴时、执行系统粘贴之前调用的闭包。
    var willPaste: (() -> Void)?

    /// 在输入未暂停时通知粘贴准备回调，并执行系统粘贴。
    override func paste(_ sender: Any?) {
        guard !isInputSuspended else { return }
        willPaste?()
        super.paste(sender)
    }

    /// 在输入未暂停时将文字交给系统文本输入实现。
    override func insertText(_ text: String) {
        guard !isInputSuspended else { return }
        super.insertText(text)
    }

    /// 在输入未暂停时执行系统向后删除操作。
    override func deleteBackward() {
        guard !isInputSuspended else { return }
        super.deleteBackward()
    }

    /// 在输入未暂停时更新输入法组合文本及其内部选区。
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard !isInputSuspended else { return }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    /// 在输入未暂停时提交当前输入法组合文本。
    override func unmarkText() {
        guard !isInputSuspended else { return }
        super.unmarkText()
    }

    /// 在输入未暂停时使用系统文本输入接口替换指定范围。
    override func replace(_ range: UITextRange, withText text: String) {
        guard !isInputSuspended else { return }
        super.replace(range, withText: text)
    }

    /// 返回当前编辑动作是否可用；输入暂停期间禁用编辑菜单动作。
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        !isInputSuspended && super.canPerformAction(action, withSender: sender)
    }
}
