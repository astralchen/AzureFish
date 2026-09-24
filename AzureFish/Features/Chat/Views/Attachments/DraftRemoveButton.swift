//
//  DraftRemoveButton.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 照片和内联附件共用的删除按钮。按 iPhone 16 Pro @3x 参考图，
/// 圆形视觉直径为 18 点；照片默认右上内缩 4 点，大圆角附件卡片可增加留白。
/// 44 点控件区域向卡片内部延伸，不随视觉边距变化。
final class DraftRemoveButton: QuickLayoutButton {
    /// 删除符号相对卡片边缘的视觉内缩量，单位为点。
    var visualInset: CGFloat = 4 {
        didSet { setNeedsQuickLayout() }
    }
    /// 承载删除符号的圆形背景视图。
    private let circleView = UIView()
    /// 显示删除叉号的图像视图。
    private let crossView = UIImageView(image: UIImage(
        systemName: "xmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
    ))

    /// 使用指定初始边框创建 `DraftRemoveButton`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        circleView.backgroundColor = UIColor(white: 0.45, alpha: 0.85)
        circleView.layer.cornerRadius = 9
        circleView.isUserInteractionEnabled = false
        crossView.tintColor = .white
        crossView.contentMode = .scaleAspectFit
        crossView.isUserInteractionEnabled = false
    }

    /// 不支持从归档创建 `DraftRemoveButton`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 按钮的高亮状态；变化时同步调整圆形背景的反馈外观。
    override var isHighlighted: Bool {
        didSet { circleView.alpha = isHighlighted ? 0.6 : 1 }
    }

    /// 延续共用删除控件的 touchUpInside 入口，VoiceOver 与触摸使用同一事件。
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    /// 保留 44 点命中区域；18 点视觉圆形随 leading/trailing 自动适配 RTL。
    override var body: Layout {
        ZStack {
            circleView.resizable()
            crossView.resizable().padding(4)
        }
        .frame(width: 18, height: 18)
        .padding(.trailing, visualInset)
        .padding(.top, visualInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
