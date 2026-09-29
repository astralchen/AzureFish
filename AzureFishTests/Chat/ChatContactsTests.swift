import AzureFishAPI
import AzureFishChat
import AzureFishProtocol
import CryptoKit
import Foundation
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
struct ChatContactsTests {
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

    @Test func displayNamesFilteringAndStableSections() {
        guard #available(iOS 16.0, *) else { return }
        let fixture = ConversationPreviewData.contacts
        let sections = ContactDirectoryPresentation.sections(fixture, query: "", locale: Locale(identifier: "zh-Hans"))
        #expect(sections.map(\.id) == ["A", "L"])
        #expect(sections.flatMap(\.contacts).count == 2)
        #expect(ContactDirectoryPresentation.sections(fixture, query: "设计", locale: Locale(identifier: "zh-Hant")).flatMap(\.contacts).first?.peer.nickname == "林沐")
        #expect(ContactDirectoryPresentation.sections(fixture, query: "不存在", locale: Locale(identifier: "en")).isEmpty)
        var first = fixture[0], second = first
        first.peer.id = "a"; second.peer.id = "b"
        #expect(ContactDirectoryPresentation.sections([second, first], query: "", locale: Locale(identifier: "ar")).flatMap(\.contacts).map(\.peer.id) == ["a", "b"])
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
