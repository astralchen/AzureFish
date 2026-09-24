import AVFoundation
import PhotosUI
import Testing
import UIKit
import QuickLayoutKitUIKit
import UniformTypeIdentifiers
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatLivePhotoTests {
    private func fixture() throws -> (URL, URL) {
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        return (bundle.appendingPathComponent("live-photo.jpg"), bundle.appendingPathComponent("live-photo.mov"))
    }

    private func item() throws -> MediaItem {
        let (photo, video) = try fixture()
        return MediaItem(assetIdentifier: nil, originalFileURL: photo, thumbnailFileURL: photo,
                         pixelSize: CGSize(width: 480, height: 640), kind: .image, livePhotoVideoURL: video)
    }

    private func reconstruct(_ photo: URL, _ video: URL) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: nil,
                                targetSize: CGSize(width: 375, height: 500), contentMode: .aspectFit) { live, info in
                guard (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true else { return }
                if let live { continuation.resume(returning: live) }
                else { continuation.resume(throwing: info[PHLivePhotoInfoErrorKey] as? Error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
    }

    @Test func liveIdentitySurvivesDraftReplyAndPreviewWithoutLabelingGIF() throws {
        let live = try item()
        let gif = MediaItem(assetIdentifier: nil, originalFileURL: live.originalFileURL,
            thumbnailFileURL: live.thumbnailFileURL, pixelSize: live.pixelSize, kind: .image, isAnimatedImage: true)
        let attachment = AzureFish.Attachment.mediaGroup(.init(items: [live, gif]))
        #expect(live.isLivePhoto && !live.isAnimatedImage && live.showsAnimatedBadge)
        #expect(!gif.isLivePhoto && gif.showsAnimatedBadge)
        let preview = AttachmentPreviewItem.prepare(attachment)
        #expect(preview.map(\.isLivePhoto) == [true, false])
        #expect(preview.allSatisfy { $0.kind == .image })
        #expect(attachment.localFileURLs.contains(try #require(live.livePhotoVideoURL)))
        let reply = try #require(attachment.simulatedReply().mediaGroup)
        #expect(reply.items[0].livePhotoVideoURL == live.livePhotoVideoURL)
        #expect(reply.items[0].id != live.id)
        let draft = MediaDraftPresentation(groupID: UUID(), items: [.init(id: live.id, assetIdentifier: nil, content: .ready(live))])
        #expect(draft.attachment?.items.first?.isLivePhoto == true)
    }

    @Test func fixtureReconstructsAndExportsAsMatchingResources() async throws {
        let (photo, video) = try fixture()
        let live = try await reconstruct(photo, video)
        #expect(live.size.width > 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = LivePhotoImportRequest()
        let resources = try await request.export(live) { folder.appendingPathComponent(UUID().uuidString).appendingPathExtension($0) }
        let exported = try await reconstruct(resources.photo, resources.video)
        #expect(exported.size == live.size)
        request.cancel()
        do {
            _ = try await request.export(live) { folder.appendingPathComponent(UUID().uuidString).appendingPathExtension($0) }
            Issue.record("Cancelled import must not export resources")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test func cancelledOriginalLookupStopsBeforeRequestingLibraryAccess() async {
        let request = LivePhotoImportRequest()
        request.cancel()
        do {
            _ = try await request.loadOriginalIfAvailable(assetIdentifier: "cancelled-selection") { _ in
                Issue.record("Cancelled lookup must not create resource URLs")
                return FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            }
            Issue.record("Cancelled lookup must throw")
        } catch is CancellationError {} catch { Issue.record(error) }
    }

    /// 使用真实实况对象提供者验证类型分流、配对导入和草稿交付。
    @Test func livePhotoProviderImportsPairedResourcesIntoDraft() async throws {
        guard #available(iOS 26.0, *) else { return }
        let (photo, video) = try fixture()
        let live = try await reconstruct(photo, video)
        // PHLivePhoto 不符合 NSItemProviderWriting；测试通过兼容初始化器注册真实对象。
        let provider = NSItemProvider(item: live, typeIdentifier: UTType.livePhoto.identifier)
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let controller = PhotoPickerController(attachmentStore: store)
        let entry = PhotoPickerController.DraftEntry(assetIdentifier: nil)
        controller.entries.append(entry)
        controller.pendingImports.append(.init(provider: provider, entry: entry, generation: controller.generation))
        controller.drainImports()
        let deadline = Date().addingTimeInterval(10)
        while !controller.activeImports.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(controller.activeImports.isEmpty)
        let imported = try #require(controller.draftAttachment?.items.first)
        #expect(imported.isLivePhoto && !imported.kind.isVideo)
        let restored = try await reconstruct(imported.originalFileURL, #require(imported.livePhotoVideoURL))
        #expect(restored.size == live.size)
        controller.discardDraft()
    }

    @Test func partialExportAndCancellationRemoveUnclaimedResources() async throws {
        let (photo, video) = try fixture()
        let live = try await reconstruct(photo, video)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for cancel in [false, true] {
            let request = LivePhotoImportRequest()
            var count = 0
            do {
                _ = try await request.export(live) { ext in
                    count += 1
                    if count == 2 {
                        if cancel { request.cancel() }
                        else { return folder.appendingPathComponent("missing/video.mov") }
                    }
                    return folder.appendingPathComponent("resource-\(count)").appendingPathExtension(ext)
                }
                Issue.record("Failed or cancelled export must not hand off partial resources")
            } catch {
                if cancel { #expect(error is CancellationError) }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    @Test func obsoleteReconstructionCannotReplaceNewPageOrReportFailure() async throws {
        let (photo, video) = try fixture()
        let player = AttachmentLivePhotoPlayer(coordinator: .init())
        var failures = 0
        player.didFail = { failures += 1 }
        player.prepare(photo: photo.appendingPathExtension("missing"), video: video, placeholder: nil, targetSize: .zero)
        player.unload()
        player.prepare(photo: photo, video: video, placeholder: nil, targetSize: CGSize(width: 375, height: 500))
        for _ in 0..<100 where !player.isReady { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(player.isReady && failures == 0)
        player.unload()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!player.isReady && !player.isPlaying && player.view.isHidden && failures == 0)
    }

    private final class DelayedAudioSession: AudioSessionControlling {
        let notificationObject: AnyObject = NSObject()
        var pending: CheckedContinuation<Void, Never>?
        var deactivations = 0
        func activateCapture() async throws {}
        func activatePlayback() async throws {}
        func activatePreviewPlayback() async throws {
            await withCheckedContinuation { pending = $0 }
        }
        func deactivate() { deactivations += 1 }
        func finish() { pending?.resume(); pending = nil }
    }

    @Test func transferringPlaybackOwnershipRejectsLateAudioActivation() async throws {
        let (photo, video) = try fixture()
        let coordinator = PlaybackCoordinator()
        let audio = DelayedAudioSession()
        let player = AttachmentLivePhotoPlayer(coordinator: coordinator, audioSession: audio)
        player.prepare(photo: photo, video: video, placeholder: nil, targetSize: CGSize(width: 375, height: 500))
        for _ in 0..<100 where !player.isReady { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(player.isReady)
        player.play()
        for _ in 0..<50 where audio.pending == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(audio.pending != nil)
        var newOwnerStopped = false
        let newOwner = UUID()
        coordinator.acquire(owner: newOwner) { newOwnerStopped = true }
        #expect(audio.deactivations == 1)
        audio.finish()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!player.isPlaying && player.view.isHidden)
        #expect(!newOwnerStopped)
        coordinator.release(owner: newOwner)
        player.unload()
    }

    @Test func continuousEffectsDecodeActualMotionAndReverseWithoutDuplicatingFrames() async throws {
        let (_, video) = try fixture()
        let frames = try await LivePhotoMotionFrames.load(video: video, targetSize: CGSize(width: 750, height: 1000))
        #expect(frames.images.count >= 60)
        #expect(frames.images.reduce(0) { $0 + $1.bytesPerRow * $1.height } < 50_000_000)
        // 比较实际解码像素，避免仅有模式名称或时间推进而画面不动。
        #expect(UIImage(cgImage: frames.images[0]).pngData() != UIImage(cgImage: frames.images[frames.images.count / 2]).pngData())
        let effect = LivePhotoMotionEffect()
        defer { effect.stop() }
        for mode: LivePhotoPlaybackMode in [.loop, .bounce] {
            effect.start(frames: frames, mode: mode)
            var indices: [Int] = []
            for _ in 0..<72 {
                try await Task.sleep(nanoseconds: 100_000_000)
                indices.append(effect.displayedFrameIndex)
            }
            #expect(Set(indices).count > 15)
            let deltas = zip(indices, indices.dropFirst()).map { $1 - $0 }
            if mode == .loop {
                #expect(deltas.contains { $0 < -frames.images.count / 2 }, "完整播放后应跳回起点")
                #expect(!deltas.contains { $0 < 0 && $0 > -frames.images.count / 2 })
            } else {
                #expect(deltas.filter { $0 > 0 }.count > 10)
                #expect(deltas.filter { $0 < 0 }.count > 10, "必须连续倒序播放，而非只重复正播")
                #expect(deltas.allSatisfy { abs($0) < frames.images.count / 2 }, "折返不能跳回起点")
            }
        }
    }

    @Test func effectSamplingUsesVideoTrackRangeInsteadOfAssumingZeroStart() async throws {
        let (_, video) = try fixture()
        let asset = AVURLAsset(url: video)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let outputTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try outputTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600)),
            of: track, at: CMTime(seconds: 0.4, preferredTimescale: 600))
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: output) }
        session.outputURL = output
        session.outputFileType = .mov
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        #expect(session.status == .completed)
        let frames = try await LivePhotoMotionFrames.load(video: output, targetSize: CGSize(width: 375, height: 500))
        #expect(!frames.images.isEmpty)
        #expect(UIImage(cgImage: frames.images[0]).pngData() != UIImage(cgImage: frames.images[frames.images.count - 1]).pngData())
    }

    @Test(arguments: Array(0..<8))
    func effectFramesMatchSystemVideoOrientation(orientation: Int) async throws {
        let (_, video) = try fixture()
        let asset = AVURLAsset(url: video)
        let source = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await source.load(.naturalSize)
        let transforms: [CGAffineTransform] = [
            .identity, .init(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
            .init(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0), .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0),
            .init(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0), .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0),
            .init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0), .init(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)
        ]
        var transform = transforms[orientation]
        let extent = CGRect(origin: .zero, size: size).applying(transform)
        transform.tx = -extent.minX
        transform.ty = -extent.minY
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
            duration: CMTime(seconds: 1, preferredTimescale: 600)), of: source, at: .zero)
        track.preferredTransform = transform
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: output) }
        session.outputURL = output
        session.outputFileType = .mov
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        #expect(session.status == .completed)
        let frames = try await LivePhotoMotionFrames.load(video: output, targetSize: CGSize(width: 375, height: 500))
        // 独立使用系统转向结果作基准，防止运动断言漏掉上下颠倒或镜像。
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 375, height: 500)
        let expected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        func sample(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            bytes.withUnsafeMutableBytes {
                let context = CGContext(data: $0.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
        }
        let differences = zip(sample(try #require(frames.images.first)), sample(expected)).map { abs(Int($0) - Int($1)) }
        #expect(Double(differences.reduce(0, +)) / Double(differences.count) < 8)
    }

    @Test func effectCancellationAndOwnershipStopPendingAndVisiblePlayback() async throws {
        let (_, video) = try fixture()
        let coordinator = PlaybackCoordinator()
        let player = AttachmentLivePhotoPlayer(coordinator: coordinator)
        var failures = 0
        player.didFail = { failures += 1 }
        let size = CGSize(width: 375, height: 500)
        player.playEffect(video: video, mode: .loop, targetSize: size)
        player.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!player.isPlaying && player.effect.view.isHidden && failures == 0)
        for mode: LivePhotoPlaybackMode in [.loop, .bounce] {
            player.playEffect(video: video, mode: mode, targetSize: size)
            for _ in 0..<200 where !player.isPlaying { try await Task.sleep(nanoseconds: 50_000_000) }
            #expect(player.isPlaying && !player.effect.view.isHidden)
            if mode == .loop {
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            } else {
                let nextOwner = UUID()
                coordinator.acquire(owner: nextOwner) {}
                coordinator.release(owner: nextOwner)
            }
            #expect(!player.isPlaying && player.effect.view.isHidden && player.effect.view.image == nil)
        }
        #expect(failures == 0)
    }

    @Test func savedPairSurvivesPageCleanupAndMissingPairFailsAtomically() async throws {
        let live = try item()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("source.jpg"), video = folder.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: live.originalFileURL, to: photo)
        try FileManager.default.copyItem(at: #require(live.livePhotoVideoURL), to: video)
        let copy = MediaItem(assetIdentifier: nil, originalFileURL: photo, thumbnailFileURL: photo,
            pixelSize: live.pixelSize, kind: .image, livePhotoVideoURL: video)
        let attachment = AzureFish.Attachment.mediaGroup(.init(items: [copy]))
        var exported: [URL] = []
        let saver = SystemAttachmentSaver(authorizePhotos: {
            try? FileManager.default.removeItem(at: photo)
            try? FileManager.default.removeItem(at: video)
            return .authorized
        }, writePhotos: { items, photos, videos in
            #expect(items.count == 1 && photos.count == 1 && videos.count == 1)
            let paired = try #require(videos.first.flatMap { $0 })
            exported = [photos[0], paired]
            _ = try await reconstruct(photos[0], paired)
        })
        #expect(try await saver.save(attachment, from: UIViewController()) == .saved)
        #expect(exported.count == 2)
        #expect(exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try FileManager.default.copyItem(at: live.originalFileURL, to: photo)
        #expect(throws: (any Error).self) { try AttachmentSaveSnapshot(attachment, parentDirectory: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["source.jpg"])
    }

    @Test func deletingReadyDraftRemovesItsPairWithoutTouchingOtherItems() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let attachment = try await AttachmentSavePreviewFixtures.resourceAttachment(named: "resources-live", store: store)
        let group = try #require(attachment.mediaGroup)
        let controller = PhotoPickerController(attachmentStore: store)
        controller.applyPreviewFixture(group)
        let removed = group.items[0]
        let retained = group.items[3]
        controller.removeItem(id: removed.id)
        for url in [removed.originalFileURL, removed.thumbnailFileURL, try #require(removed.livePhotoVideoURL)] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: try #require(retained.livePhotoVideoURL).path))
        controller.discardDraft()
        #expect(!FileManager.default.fileExists(atPath: try #require(retained.livePhotoVideoURL).path))
    }

    @Test func menuSelectionIsPerItemPerPreviewAndHiddenWithChrome() throws {
        guard #available(iOS 26.0, *) else { return }
        let live = try item()
        let ordinary = MediaItem(assetIdentifier: nil, originalFileURL: live.originalFileURL,
            thumbnailFileURL: live.thumbnailFileURL, pixelSize: live.pixelSize, kind: .image)
        let items = AttachmentPreviewItem.prepare(.mediaGroup(.init(items: [live, ordinary])))
        let controller = AttachmentPreviewController(items: items, initialIndex: 0, playbackCoordinator: .init())
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { controller.completeDismissal(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let button = controller.chrome.livePhotoButton
        #expect(!button.isHidden)
        #expect((button.menu?.children.first as? UIAction)?.state == .on)
        #expect(button.menu?.children.count == 4)
        for mode: LivePhotoPlaybackMode in [.loop, .bounce] {
            controller.setLivePhotoMode(mode)
            #expect(button.accessibilityValue == Localization.text(mode.titleKey))
            let actions = button.menu?.children.compactMap { $0 as? UIAction } ?? []
            #expect(actions.filter { $0.state == .on }.map(\.title) == [Localization.text(mode.titleKey)])
            controller.select(1, animated: false)
            #expect(button.isHidden)
            controller.select(0, animated: false)
            #expect(button.accessibilityValue == Localization.text(mode.titleKey))
        }
        controller.setLivePhotoMode(.off)
        #expect((button.menu?.children.last as? UIAction)?.state == .on)
        controller.select(1, animated: false)
        #expect(button.isHidden)
        controller.select(0, animated: false)
        #expect(!button.isHidden)
        #expect((button.menu?.children.last as? UIAction)?.state == .on)
        controller.toggleControls()
        #expect(!controller.chrome.controlsVisible && controller.chrome.accessibilityElementsHidden)
        controller.toggleControls()
        #expect((button.menu?.children.last as? UIAction)?.state == .on)
        let reopened = AttachmentPreviewController(items: items, initialIndex: 0, playbackCoordinator: .init())
        reopened.loadViewIfNeeded()
        #expect((reopened.chrome.livePhotoButton.menu?.children.first as? UIAction)?.state == .on)
        reopened.completeDismissal()
    }

    @Test func badgeFitsSELandscapeAndRTLWithExpandedHitArea() {
        guard #available(iOS 26.0, *) else { return }
        for size in [CGSize(width: 375, height: 667), CGSize(width: 667, height: 375)] {
            for direction: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
                let chrome = AttachmentPreviewControlsView(items: [], selectedIndex: 0)
                chrome.frame = CGRect(origin: .zero, size: size)
                chrome.semanticContentAttribute = direction
                chrome.updateItem(title: "照片", position: "1 / 1", isPlayable: false)
                chrome.updateLivePhoto(isLivePhoto: true, mode: .live)
                let photo = AVMakeRect(aspectRatio: CGSize(width: 480, height: 640), insideRect: chrome.bounds)
                chrome.updatePhotoRect(photo)
                chrome.layoutIfNeeded()
                let button = chrome.livePhotoButton
                #expect(button.frame.minX >= 16 && button.frame.maxX <= size.width - 16)
                #expect(button.frame.minY >= photo.minY + 6)
                #expect(button.frame.minX >= photo.minX + 16 && button.frame.maxX <= photo.maxX - 16)
                #expect(button.frame.height >= 20 && button.frame.height <= 36)
                #expect(button.point(inside: CGPoint(x: button.bounds.midX, y: button.bounds.midY + 21), with: nil))
                #expect(chrome.hitTest(CGPoint(x: size.width / 2, y: size.height / 2), with: nil) == nil)
            }
        }
    }

    @Test func systemPlaybackStopsOnDisablePagingAndBackground() async throws {
        guard #available(iOS 26.0, *) else { return }
        let items = AttachmentPreviewItem.prepare(.mediaGroup(.init(items: [try item()])))
        let controller = AttachmentPreviewController(items: items, initialIndex: 0, playbackCoordinator: .init())
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { controller.completeDismissal(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let page = try #require(controller.currentPage)
        let player = try #require(page.livePhotoPlayer)
        for _ in 0..<100 where !player.isReady { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(player.isReady)
        player.play()
        for _ in 0..<50 where !player.isPlaying { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(player.isPlaying)
        controller.setLivePhotoMode(.off)
        #expect(!player.isPlaying && !player.isReady && player.view.isHidden)
        controller.setLivePhotoMode(.live)
        for _ in 0..<100 where !player.isReady { try await Task.sleep(nanoseconds: 100_000_000) }
        player.play()
        for _ in 0..<50 where !player.isPlaying { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(player.isPlaying)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(!player.isPlaying)
        controller.scrollViewWillBeginDragging(controller.collectionView)
        #expect(!player.isReady)
    }
}
