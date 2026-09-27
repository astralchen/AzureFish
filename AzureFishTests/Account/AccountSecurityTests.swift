import UIKit
import Testing
@testable import AzureFish

@Suite("账号安全列表", .serialized)
@MainActor
struct AccountSecurityTests {
    private func settle(_ controller: AccountSecurityViewController) async {
        for _ in 0..<12 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            controller.collectionView.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @Test func groupedRowsFitContainersAndExposeReadOnlyState() async {
        let controller = AccountSecurityViewController(session: .configured())
        controller.loadViewIfNeeded()
        for width: CGFloat in [320, 390, 1024] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1400)
            await settle(controller)
            let list = controller.collectionView
            #expect(list.numberOfSections == 3)
            for (section, count) in [2, 2, 1].enumerated() {
                #expect(list.numberOfItems(inSection: section) == count)
                for item in 0..<count {
                    let path = IndexPath(item: item, section: section)
                    let cell = list.cellForItem(at: path) as? UICollectionViewListCell
                    #expect(cell != nil)
                    #expect(cell?.accessories.isEmpty == true)
                    let frame = list.layoutAttributesForItem(at: path)?.frame ?? .zero
                    #expect(frame.width <= 600.5 && frame.minX >= 23.5 && frame.maxX <= width - 23.5)
                    #expect(frame.height >= 44)
                    let readOnly = section == 0 && item == 0
                    #expect(cell?.accessibilityTraits.contains(.button) == !readOnly)
                    if readOnly { #expect(cell?.accessibilityTraits.contains(.staticText) == true) }
                }
            }
            let path = IndexPath(item: 0, section: 0)
            let footer = list.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: path)
            #expect(footer != nil)
            footer?.layoutIfNeeded()
            let labels = footer?.subviews.compactMap { $0 as? UILabel } ?? []
            #expect(!labels.isEmpty)
            for label in labels {
                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                #expect(label.bounds.height >= ceil(needed.height) - 1)
            }
            #expect(list.delegate?.collectionView?(list, shouldSelectItemAt: path) == false)
        }
        if #available(iOS 17.0, *) {
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.frame.size.width = 320
            await settle(controller)
            let frame = controller.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame ?? .zero
            #expect(frame.height > 70)
        }
    }
}
