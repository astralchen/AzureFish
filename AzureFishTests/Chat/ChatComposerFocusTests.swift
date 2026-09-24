import Testing
import UIKit
import QuickLayoutKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatComposerFocusTests {
    @Test func singleLineCaretAndPlaceholderStayVerticallyCentered() throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let composer = ComposerView(
            frame: CGRect(x: 0, y: 100, width: 402, height: 60)
        )
        composer.configure(strings: ConversationPreviewData.composerStrings)
        controller.view.addSubview(composer)
        composer.layoutIfNeeded()
        #expect(composer.textView.becomeFirstResponder())
        for text in ["", "Hello", "你好", "one\ntwo\nthree", "Hello", ""] {
            composer.textView.text = text
            composer.textViewDidChange(composer.textView)
            composer.frame.size.height = composer.intrinsicContentSize.height
            composer.setNeedsQuickLayout()
            composer.layoutIfNeeded()
            composer.textView.layoutIfNeeded()
            let editor = composer.textView
            if text.contains("\n") {
                #expect(editor.bounds.height > 44)
                #expect(editor.textContainerInset.top == 8)
                continue
            }
            let caret = editor.caretRect(for: editor.beginningOfDocument)
            #expect(abs(caret.midY - editor.bounds.midY) < 1,
                    "Text: \(text), caret: \(caret), editor: \(editor.bounds)")
            #expect(abs(editor.bounds.height - 44) < 0.5)
            if text.isEmpty {
                let placeholder = composer.placeholderLabel.convert(
                    composer.placeholderLabel.bounds, to: editor
                )
                #expect(abs(placeholder.midY - editor.bounds.midY) < 1)
            }
        }
    }

    @Test func audioStatesPreserveUserSelectedTextFocus() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let composer = ComposerView(
            frame: CGRect(x: 0, y: 100, width: 390, height: 80)
        )
        controller.view.addSubview(composer)
        composer.layoutIfNeeded()
        let preview = ComposerState.audioPreview(
            attachment: AudioAttachment(
                fileURL: URL(fileURLWithPath: "/tmp/composer-focus.m4a"),
                duration: 2,
                waveform: [0.2, 0.5]
            ),
            isPlaying: false,
            progress: 0
        )
        let states: [ComposerState] = [
            .recording(elapsed: 0, waveform: [0.2]), preview, .idle
        ]
        // 模拟用户先点文本框，再切换录音、预览、返回文本；过程中不能丢失焦点。
        #expect(composer.textView.becomeFirstResponder())
        for state in states {
            composer.applyState(state)
            composer.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(composer.textView.isFirstResponder, "Focus lost in \(state)")
        }
        // 用户主动收起键盘后，相同切换也不能重新取得文本焦点。
        composer.textView.resignFirstResponder()
        for state in states {
            composer.applyState(state)
            composer.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(!composer.textView.isFirstResponder)
        }
    }
}
