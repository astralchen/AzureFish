import AzureFishAPI
import AzureFishChat
import AzureFishProtocol
import CryptoKit
import Foundation
import ListKit
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
struct ChatContactsTests {
    @Test func indexFollowsSearchAndStaysAtSemanticTrailingEdge() async throws {
        guard #available(iOS 16.0, *) else { return }
        let controller = ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.indexedContacts))
        controller.loadViewIfNeeded()
        for _ in 0..<100 where controller.sectionIndex.titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.sectionIndex.titles.count == 27)
        for direction: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
            controller.view.semanticContentAttribute = direction
            for width: CGFloat in [320, 768] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
                controller.setNeedsQuickLayout()
                controller.view.layoutIfNeeded()
                let index = controller.sectionIndex.frame
                let list = controller.list.frame
                #expect(index.width == 44)
                #expect(list.minX == 0 && list.width == width)
                if direction == .forceLeftToRight { #expect(index.maxX == list.maxX) }
                else { #expect(index.minX == list.minX) }
                controller.list.layoutIfNeeded()
                for cell in controller.list.visibleCells {
                    #expect(abs(cell.frame.width - list.width) < 1)
                }
            }
        }
        let search = try #require(controller.navigationItem.searchController)
        search.searchBar.text = "NoSuchContact"
        controller.updateSearchResults(for: search)
        for _ in 0..<100 where !controller.sectionIndex.titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.sectionIndex.isHidden)
        #expect(controller.sectionIndex.titles.isEmpty)
        search.searchBar.text = ""
        controller.updateSearchResults(for: search)
        for _ in 0..<100 where controller.sectionIndex.titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.sectionIndex.titles.count == 27)
    }

    @Test func indexedCellsFillListAndKeepContentOutsideIndex() async throws {
        guard #available(iOS 16.0, *) else { return }
        let controller = ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where controller.sectionIndex.titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded(); controller.view.layoutIfNeeded(); controller.list.layoutIfNeeded()
        let cell = try #require(controller.list.visibleCells.first { $0 is ContactDirectoryCell })
        cell.isSelected = true
        cell.layoutIfNeeded()
        #expect(abs(cell.frame.width - controller.list.bounds.width) < 1)
        #expect(cell.accessibilityTraits.contains(.button))
        #expect(!cell.accessibilityTraits.contains(.image))
        let index = controller.sectionIndex.convert(controller.sectionIndex.bounds, to: cell)
        func visibleContent(in view: UIView) -> [UIView] {
            view.subviews.flatMap { child -> [UIView] in
                guard !child.isHidden, child.alpha > 0 else { return [] }
                if child is UILabel || child is UIImageView { return [child] }
                return visibleContent(in: child)
            }
        }
        let content = visibleContent(in: cell)
        #expect(!content.isEmpty)
        for view in content {
            #expect(view.convert(view.bounds, to: cell).maxX <= index.minX)
        }
        let footer = try #require(controller.list.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter).first)
        #expect(abs(footer.frame.midX - controller.list.bounds.midX) < 1)
    }

    @Test func contactAvatarsAndTextStayVerticallyCenteredInRealList() async throws {
        guard #available(iOS 16.0, *) else { return }
        let controller = ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 1000))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where controller.sectionIndex.titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        func labels(in view: UIView) -> [UILabel] {
            view.subviews.flatMap { child -> [UILabel] in
                if let label = child as? UILabel { return label.isHidden ? [] : [label] }
                return labels(in: child)
            }
        }
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        for category: UIContentSizeCategory in [.large, .accessibilityExtraExtraExtraLarge] {
            navigation.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            for direction: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
                controller.view.semanticContentAttribute = direction
                for width: CGFloat in [320, 768] {
                    window.frame.size.width = width
                    controller.setNeedsQuickLayout()
                    try await Task.sleep(for: .milliseconds(100))
                    window.layoutIfNeeded(); controller.view.layoutIfNeeded(); controller.list.layoutIfNeeded()
                    let cells = controller.list.visibleCells.compactMap { $0 as? ContactDirectoryCell }
                    #expect(cells.count == 2)
                    for cell in cells {
                        for selected in [false, true] {
                            cell.isSelected = selected
                            for image in [UIImage(systemName: "person.crop.circle.fill"), photo] {
                                cell.avatar.image = image
                                cell.setNeedsLayout(); cell.layoutIfNeeded()
                                try await Task.sleep(for: .milliseconds(20))
                                let avatar = cell.avatar.convert(cell.avatar.bounds, to: cell)
                                #expect(abs(avatar.width - 44) < 0.01 && abs(avatar.height - 44) < 0.01)
                                #expect(abs(avatar.midY - cell.bounds.midY) < 1)
                                #expect(avatar.minY >= cell.bounds.minY && avatar.maxY <= cell.bounds.maxY)
                                let text = labels(in: cell.contentView).filter { $0.text?.isEmpty == false }
                                    .reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: cell)) }
                                #expect(!text.isNull)
                                #expect(abs(text.midY - cell.bounds.midY) < 1)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func indexConsumesHorizontalSafeAreaOnceAndUsesListVerticalInsets() async throws {
        guard #available(iOS 16.0, *) else { return }
        let controller = ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.indexedContacts))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        defer { window.isHidden = true }
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 30, bottom: 25, right: 15)
        for _ in 0..<100 where controller.sectionIndex.titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        for direction: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
            controller.view.semanticContentAttribute = direction
            controller.setNeedsQuickLayout()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            let index = controller.sectionIndex
            index.layoutIfNeeded()
            let safe = controller.view.bounds.inset(by: controller.view.safeAreaInsets)
            #expect(controller.view.safeAreaInsets.left >= 30)
            #expect(controller.view.safeAreaInsets.right >= 15)
            let rail = index.convert(index.bounds, to: controller.view)
            #expect(rail.minX >= safe.minX - 1)
            #expect(rail.maxX <= safe.maxX + 1)
            #expect(rail.width == 44)
            let list = controller.list.convert(controller.list.bounds, to: controller.view)
            #expect(abs(list.minX - safe.minX) < 1)
            #expect(abs(list.maxX - safe.maxX) < 1)
            #expect(index.contentInsets.left == 0 && index.contentInsets.right == 0)
            #expect(index.contentInsets.top == controller.list.adjustedContentInset.top)
            #expect(index.contentInsets.bottom == controller.list.adjustedContentInset.bottom)
            let first = index.convert(index.rectForTitle(at: 0), to: controller.view)
            let last = index.convert(index.rectForTitle(at: 26), to: controller.view)
            #expect(first.minY >= safe.minY - 1)
            #expect(last.maxY <= safe.maxY + 1)
        }
    }

    @Test func profileAvatarKeepsSquareSizeAcrossContainerAndImageChanges() throws {
        guard #available(iOS 16.0, *) else { return }
        let controller = FriendViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact)
        controller.loadViewIfNeeded()
        func findAvatar(in view: UIView) -> AccountAvatarView? {
            if let avatar = view as? AccountAvatarView { return avatar }
            return view.subviews.lazy.compactMap { findAvatar(in: $0) }.first
        }
        for width: CGFloat in [320, 402, 768] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 874)
            controller.setNeedsQuickLayout()
            controller.view.layoutIfNeeded()
            let avatar = try #require(findAvatar(in: controller.view))
            for imageSize: CGSize in [.zero, CGSize(width: 240, height: 120), CGSize(width: 120, height: 240)] {
                if imageSize == .zero {
                    avatar.image = UIImage(systemName: "person.crop.circle.fill")
                } else {
                    avatar.image = UIGraphicsImageRenderer(size: imageSize).image { context in
                        UIColor.systemBlue.setFill()
                        context.fill(CGRect(origin: .zero, size: imageSize))
                    }
                }
                controller.setNeedsQuickLayout()
                controller.view.layoutIfNeeded()
                avatar.superview?.layoutIfNeeded()
                avatar.layoutIfNeeded()
                #expect(avatar.bounds.size == CGSize(width: 64, height: 64))
                #expect(avatar.layer.cornerRadius == 32)
                let name = try #require(controller.fields.dropFirst().first)
                #expect(avatar.convert(avatar.bounds, to: controller.view).maxY <= name.convert(name.bounds, to: controller.view).minY)
            }
        }
    }

    @Test func requestAvatarUsesItsReservedSquareInsteadOfSymbolIntrinsicSize() {
        guard #available(iOS 16.0, *) else { return }
        let cell = ContactRequestCell(frame: CGRect(x: 0, y: 0, width: 390, height: 360))
        cell.configure(ConversationPreviewData.contacts[2], detail: "Fixture", busy: false, accepted: {})
        cell.setNeedsQuickLayout(); cell.layoutIfNeeded()
        func findAvatar(_ view: UIView) -> AccountAvatarView? {
            (view as? AccountAvatarView) ?? view.subviews.lazy.compactMap { findAvatar($0) }.first
        }
        #expect(findAvatar(cell)?.bounds.size == CGSize(width: 44, height: 44))
    }

    @Test func memberOpensCachedContactWithoutNetworkRuntime() throws {
        guard #available(iOS 16.0, *) else { return }
        var member = ConversationPreviewData.detailsConversation().members[1]
        let contact = ConversationPreviewData.contact
        member.id = contact.peer.id; member.profile = contact.peer
        let runtime = ChatRuntime(previewContacts: [contact])
        #expect(runtime.engine == nil)
        let controller = ConversationMemberViewController(runtime: runtime, member: member)
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let open = try #require(controller.actions.compactMap { $0 as? UIButton }.first)
        open.sendActions(for: .touchUpInside)
        #expect(navigation.topViewController is FriendViewController)
    }

    @Test func searchPlaceholderAvoidsDockedKeyboardAndRestoresInsets() async throws {
        guard #available(iOS 16.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let controller = ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        controller.loadViewIfNeeded()
        let search = try #require(controller.navigationItem.searchController)
        search.searchBar.text = "NoSuchContact"
        controller.updateSearchResults(for: search)
        try await Task.sleep(nanoseconds: 200_000_000)
        window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        let keyboard = CGRect(x: 0, y: window.bounds.height - 300, width: window.bounds.width, height: 300)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: window.screen.coordinateSpace))])
        let state = try #require(controller.list.backgroundView as? ChatListStateView)
        state.layoutIfNeeded()
        #expect(abs(controller.list.adjustedContentInset.bottom - 300) < 1)
        #expect(state.content.convert(state.content.bounds, to: window).maxY <= keyboard.minY)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(controller.list.contentInset.bottom == 0)
    }

    @Test func displayNamesFilteringAndStableSections() {
        guard #available(iOS 16.0, *) else { return }
        let fixture = ConversationPreviewData.contacts
        let sections = ContactDirectoryPresentation.sections(fixture, query: "")
        #expect(sections.map(\.id) == ["A", "L"])
        #expect(sections.flatMap(\.contacts).count == 2)
        #expect(ContactDirectoryPresentation.sections(fixture, query: "设计").flatMap(\.contacts).first?.peer.nickname == "林沐")
        #expect(ContactDirectoryPresentation.sections(fixture, query: "不存在").isEmpty)
        var first = fixture[0], second = first
        first.peer.id = "a"; second.peer.id = "b"
        #expect(ContactDirectoryPresentation.sections([second, first], query: "").flatMap(\.contacts).map(\.peer.id) == ["a", "b"])
    }

    @Test func directoryUsesPinyinAndOnlyLatinIndexTitles() {
        guard #available(iOS 16.0, *) else { return }
        let names = ["小林", "林沐", "吕布", "李安", "陳晨", "张三", "Zoe", "Émile", "Ａlice", "123", "علي", "😀", ""]
        let contacts = names.enumerated().map { index, name in
            var contact = ConversationPreviewData.contact
            contact.peer.id = String(index)
            contact.peer.nickname = name
            contact.remark = ""
            return contact
        }
        let sections = ContactDirectoryPresentation.sections(contacts, query: "")
        #expect(sections.map(\.id) == ["A", "C", "E", "L", "X", "Z", "#"])
        #expect(sections.first { $0.id == "L" }?.contacts.map(\.displayName) == ["李安", "林沐", "吕布"])
        #expect(sections.first { $0.id == "Z" }?.contacts.map(\.displayName) == ["张三", "Zoe"])
        #expect(sections.first { $0.id == "X" }?.contacts.map(\.displayName) == ["小林"])
        #expect(sections.last?.contacts.count == 4)
        var remarked = contacts[0]
        remarked.remark = "阿林"
        #expect(ContactDirectoryPresentation.sections([remarked], query: "小林").map(\.id) == ["A"])
    }
    @Test func oldCacheCannotEnableNewMutations() throws {
        let bytes = Data(#"{"id":"old","peer":{"id":"peer","nickname":"名字","version":1},"state":"friend","requesterID":"me","revision":3,"updatedAt":100}"#.utf8)
        let contact = try JSONDecoder().decode(ChatContact.self, from: bytes)
        #expect(contact.isContact && contact.remark.isEmpty && !contact.isBlocked)
        #expect(!contact.canSend && !contact.allows(.delete))
    }
    @Test func staleEventsCannotRestoreDeletedContactAndOperationsCanClear() async throws {
        guard #available(iOS 16.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "contacts-test", userID: UUID())
        var contact = ConversationPreviewData.contact
        try await store.save(contact)
        let old = contact
        contact.revision += 1; contact.isContact = false; contact.state = "deleted"; contact.availableActions = ["restore", "block", "remark"]
        try await store.save(contact); try await store.save(old)
        #expect(try await store.contacts().first?.isContact == false)
        var renamed = old
        renamed.peer.version += 1; renamed.peer.nickname = "最新昵称"
        try await store.save(renamed)
        let merged = try #require(try await store.contacts().first)
        #expect(!merged.isContact && merged.peer.nickname == "最新昵称")
        contact.revision += 1; contact.remark = "新的私有备注"
        try await store.save(contact)
        let latest = try #require(try await store.contacts().first)
        #expect(latest.displayName == "新的私有备注" && latest.peer.nickname == "最新昵称")
        #expect(latest.matches("最新昵称") && !latest.isContact)
        try await store.setMeta(Data([1,2,3]), id: "pending")
        try await store.removeMeta("pending")
        let restored: Data? = try await store.meta("pending")
        #expect(restored == nil)
        try await store.close()
    }
}
