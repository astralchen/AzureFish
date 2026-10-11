import AppLocalization
import AzureFishAPI
import AzureFishChat
import AzureFishMoments
import AzureFishStorage
import CryptoKit
import Foundation
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite("朋友圈账号存储")
/// 覆盖账号库迁移、独立草稿、墓碑与共享媒体引用，并检查基础布局和本地化资源。
struct MomentsStorageTests {
    @Test func upgradeKeepsChatAndRestoresIndependentDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("main.sqlite"), user = UUID(), key = Data(repeating: 71, count: 32)
        let old = try ChatStore(url: url, key: key, environment: "moments-test", userID: user)
        try await old.saveDraft(.init(text: "existing chat draft"), conversation: "fixture")
        try await old.close()
        let database = try ChatStore.openDatabase(url: url, key: key, environment: "moments-test", userID: user, migrations: [MomentsStore.migration])
        let chat = try ChatStore(database: database), moments = try MomentsStore(database: database)
        #expect(try await chat.draft("fixture").text == "existing chat draft")
        var one = MomentsDraft(); one.text = "PRIVATE-MOMENTS-DRAFT"
        one.publication = try MomentsAPI.publication(id: one.id, operation: one.operation, text: one.text, assets: [])
        var two = MomentsDraft(); two.text = "another scene"
        try await moments.save(one); try await moments.save(two)
        await moments.close(); try await chat.close(); try database.close()
        let reopened = try ChatStore.openDatabase(url: url, key: key, environment: "moments-test", userID: user, migrations: [MomentsStore.migration])
        let restored = try MomentsStore(database: reopened)
        #expect(try await restored.drafts().count == 2)
        #expect(try await restored.drafts().first { $0.id == one.id }?.publication == one.publication)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(one.text))
        await restored.close(); try reopened.close()
        #expect(throws: (any Error).self) { try ChatStore.openDatabase(url: url, key: Data(repeating: 72, count: 32), environment: "moments-test", userID: user, migrations: [MomentsStore.migration]) }
    }
    @Test func tombstonesAndSharedMediaReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 71, count: 32)
        let resources = try await AccountBusinessStorage.acquire(root: root, databaseKey: key, mediaKey: key, environment: "moments-test", userID: user)
        let store = try MomentsStore(database: resources.resources.database), media = resources.resources.media
        let author = ChatUser(id: user.uuidString.lowercased(), nickname: "Fixture", version: 1, avatarID: nil, deleted: false)
        let post = MomentsPost(id: UUID().uuidString, author: author, text: "old", createdAt: 1, revision: 1)
        var deleted = post; deleted.deleted = true; deleted.text = ""; deleted.revision = 2
        try await store.merge([post, deleted, post]); #expect(try await store.posts().isEmpty)
        let id = UUID(), bytes = Data("private image fixture".utf8)
        let descriptor = MediaResourceDescriptor(role: "moments-draft", filename: "fixture.jpg", mime: "image/jpeg", bytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try await store.reserve(id); try await media.prepare(id: id, input: descriptor)
        try await media.write(bytes, id: id, index: 0); try await media.verify(id)
        var one = MomentsDraft(); one.images = [.init(id: id, descriptor: descriptor)]
        var two = MomentsDraft(); two.images = one.images
        try await store.save(one); try await store.save(two); try await store.finishImport(id)
        try await store.removeDraft(one.id)
        #expect(try await !media.removeIfUnreferenced(id, database: resources.resources.database))
        #expect(try await media.read(id, index: 0) == bytes)
        try await store.removeDraft(two.id)
        try await store.recoverCleanup(media: media)
        await #expect(throws: (any Error).self) { try await media.read(id, index: 0) }
        await store.close(); try await resources.release()
    }
    @Test func longPostLayoutAndFourLanguageKeys() {
        Localization.start()
        let original = Localization.localizationController.currentLocale.identifier
        let followedSystem = Localization.localizationController.followsSystemLocale
        defer {
            if followedSystem { Localization.localizationController.setFollowsSystemLocale() }
            else { Localization.setLocale(identifier: original) }
        }
        let runtime = MomentsPreviewData.runtime()
        var post = MomentsPreviewData.posts[0]; post.text = String(repeating: "长文本 مرحباً Hello ", count: 100)
        let view = MomentsPostContentView(configuration: MomentsPostConfiguration(post: post, media: MomentsMediaProvider(runtime: runtime), width: 320, expanded: true, action: { _ in }))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 1200); view.layoutIfNeeded()
        #expect(view.subviews.count > 0)
        var draft = MomentsDraft(); draft.text = "Unsubmitted input مرحباً"
        let editor = MomentsComposerViewController(runtime: runtime, draft: draft)
        editor.loadViewIfNeeded()
        func inputs(_ view: UIView) -> [UITextView] { (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(inputs) }
        for locale in ["zh-Hans", "zh-Hant", "ar", "en-US"] {
            Localization.setLocale(identifier: locale)
            editor.reloadLayoutDirection(Localization.currentUIKitDirection); editor.reloadLocalizedContent()
            editor.view.frame = CGRect(x: 0, y: 0, width: locale == "ar" ? 700 : 320, height: 844); editor.view.layoutIfNeeded()
            #expect(inputs(editor.view).first?.text == draft.text)
            for key in ["moments.title", "moments.album", "moments.publish", "moments.failed"] { #expect(Localization.text(key) != key) }
        }
        #expect(Localization.currentUIKitDirection == .leftToRight)
    }
    @Test func photoCountsReuseAndWideContainerLimits() throws {
        let runtime = MomentsPreviewData.runtime()
        var post = MomentsPreviewData.posts[0]
        func configuration(width: CGFloat) -> MomentsPostConfiguration {
            MomentsPostConfiguration(post: post, media: MomentsMediaProvider(runtime: runtime), width: width, expanded: false, action: { _ in })
        }
        let view = MomentsPostContentView(configuration: configuration(width: 390))
        func photos(in parent: UIView) -> [UIView] {
            parent.subviews.flatMap { child in
                child.accessibilityIdentifier?.hasPrefix("moments.photo.") == true ? [child] : photos(in: child)
            }.sorted { ($0.accessibilityIdentifier ?? "") < ($1.accessibilityIdentifier ?? "") }
        }
        // 同一个内容视图反复换数量、方向和宽度，检查真实子视图几何及复用清理。
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            view.semanticContentAttribute = direction
            for width in [CGFloat(320), 390, 720, 1200] {
                for count in (0...9).reversed() {
                    post.images = Array(MomentsPreviewData.images.prefix(count))
                    view.configuration = configuration(width: width)
                    view.frame = CGRect(x: 0, y: 0, width: width, height: 1800); view.layoutIfNeeded()
                    let frames = photos(in: view).map { $0.convert($0.bounds, to: view) }
                    #expect(frames.count == count)
                    for frame in frames {
                        #expect(frame.width > 0 && frame.height > 0)
                        #expect(frame.minX >= 0 && frame.maxX <= width)
                    }
                    guard count > 0 else { continue }
                    let first = try #require(frames.first)
                    let area = frames.reduce(CGRect.null) { $0.union($1) }
                    #expect(area.width <= 320)
                    if count == 1 {
                        #expect(abs(first.width / first.height - 4 / 3) < 0.02)
                        #expect(first.width <= 280 && first.height <= 360)
                    } else {
                        #expect(abs(first.width - first.height) < 1)
                        let rows = Dictionary(grouping: frames, by: { Int($0.minY.rounded()) }).values.map(\.count).sorted()
                        let expected = [2: [2], 3: [3], 4: [2, 2], 5: [2, 3], 6: [3, 3], 7: [1, 3, 3], 8: [2, 3, 3], 9: [3, 3, 3]]
                        #expect(rows == expected[count])
                        if width >= 720 { #expect(first.width <= 104) }
                    }
                }
                let dimensionsToTest: [(Int32, Int32)] = [(120, 160), (100, 1000), (1000, 100), (0, 0)]
                for dimensions in dimensionsToTest {
                    post.images = [MomentsPreviewData.images[0]]
                    post.images[0].width = dimensions.0; post.images[0].height = dimensions.1
                    view.configuration = configuration(width: width); view.layoutIfNeeded()
                    let size = try #require(photos(in: view).first).bounds.size
                    let ratio = dimensions.0 == 0 ? 1 : CGFloat(dimensions.0) / CGFloat(dimensions.1)
                    #expect(abs(size.width - size.height * ratio) < max(1, ratio))
                    #expect(size.width <= 280 && size.height <= 360)
                }
            }
        }
    }
}
