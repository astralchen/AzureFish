//
//  PhotoPickerController+SheetHost.swift
//  Demo
//

import AVFoundation
import ImageIO
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 承载系统照片选择器并提供可测量面板。
@available(iOS 17.0, *)
extension PhotoPickerController {

    /// PHPicker 在 iOS 26 会使用全屏透明承载视图；独立 Sheet Host 保证公开的
    /// `UIPresentationController.presentedView` 就是可见面板，便于逐帧读取几何。
    final class SheetHostController: UIViewController {
        /// 作为子控制器嵌入可测量面板的系统照片选择器。
        let picker: PHPickerViewController

        /// 创建承载指定照片选择器的面板宿主控制器。
        init(picker: PHPickerViewController) {
            self.picker = picker
            super.init(nibName: nil, bundle: nil)
        }

        /// 不支持从归档创建 `SheetHostController`。
        ///
        /// 请使用代码初始化方法创建此对象。
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 建立照片选择器的子控制器关系，由系统管理网格内容边距。
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            view.clipsToBounds = true
            addChild(picker)
            view.addSubview(picker.view)
            picker.didMove(toParent: self)
        }

        /// 将照片选择器完整放入宿主边界，避免负向偏移裁掉第一行缩略图。
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            picker.view.frame = view.bounds
        }
    }
}
