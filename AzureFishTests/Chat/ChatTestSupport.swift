import AVFAudio
import CoreGraphics
import Testing
import UIKit
import AppLocalization
import QuickLayoutKit
@_spi(Testing) import QuickLayoutKitUIKit
@testable import AzureFish

extension DemoTests {
    func layout(
        _ viewController: LocalizedQuickLayoutHostingController,
        in navigationController: UINavigationController
    ) {
        navigationController.view.setNeedsLayout()
        navigationController.view.layoutIfNeeded()
        viewController.setNeedsQuickLayout()
        viewController.quickLayoutIfNeeded()
        viewController.view.layoutIfNeeded()
    }
}

@MainActor
func makeVisibleTestWindow(
    rootViewController: UIViewController,
    size: CGSize? = nil,
    semanticContentAttribute: UISemanticContentAttribute = .unspecified,
    contentSizeCategory: UIContentSizeCategory? = nil
) throws -> UIWindow {
    let windowScene = try #require(
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    )
    let window = UIWindow(windowScene: windowScene)
    let sceneSize: CGSize
    if #available(iOS 26.0, *) {
        sceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size
    } else {
        sceneSize = windowScene.coordinateSpace.bounds.size
    }
    window.frame = CGRect(
        origin: .zero,
        size: size ?? sceneSize
    )
    window.semanticContentAttribute = semanticContentAttribute
    if let contentSizeCategory {
        if #available(iOS 17.0, *) {
            rootViewController.traitOverrides.preferredContentSizeCategory = contentSizeCategory
            window.rootViewController = rootViewController
        } else {
            let container = UIViewController()
            window.rootViewController = container
            container.addChild(rootViewController)
            container.setOverrideTraitCollection(
                UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
                forChild: rootViewController
            )
            container.view.addSubview(rootViewController.view)
            rootViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            rootViewController.didMove(toParent: container)
        }
    } else {
        window.rootViewController = rootViewController
    }
    window.isHidden = false
    rootViewController.view.frame = window.bounds
    rootViewController.view.setNeedsLayout()
    rootViewController.view.layoutIfNeeded()
    return window
}

@MainActor
func activate(_ control: UIControl) {
    if let button = control as? QuickLayoutButton {
        button.performAction()
    } else {
        control.sendActions(for: .touchUpInside)
    }
}

@MainActor
func waitForCondition(
    attempts: Int = 200,
    _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

func isHorizontalMirror(
    _ frame: CGRect,
    of originalFrame: CGRect,
    in containerWidth: CGFloat,
    tolerance: CGFloat = 1
) -> Bool {
    abs(frame.midX - (containerWidth - originalFrame.midX)) < tolerance
        && abs(frame.midY - originalFrame.midY) < tolerance
        && abs(frame.width - originalFrame.width) < tolerance
        && abs(frame.height - originalFrame.height) < tolerance
}

extension CGPoint {
    func approximatelyEquals(
        _ other: CGPoint,
        tolerance: CGFloat = 1
    ) -> Bool {
        abs(x - other.x) < tolerance
            && abs(y - other.y) < tolerance
    }
}

extension CGRect {
    func approximatelyEquals(
        _ other: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        abs(minX - other.minX) < tolerance
            && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance
            && abs(height - other.height) < tolerance
    }
}

extension String {
    /// Foundation may add Unicode bidi-isolation marks around formatted
    /// substitutions on newer SDKs. They are correct for rendering but should
    /// not make localized copy assertions SDK-dependent.
    var removingBidiIsolationMarks: String {
        replacingOccurrences(of: "\u{2066}", with: "")
            .replacingOccurrences(of: "\u{2067}", with: "")
            .replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
    }
}

extension UIView {
    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches: [T] = []
            if let typed = subview as? T {
                matches.append(typed)
            }
            matches.append(contentsOf: subview.allSubviews(of: type))
            return matches
        }
    }
}
