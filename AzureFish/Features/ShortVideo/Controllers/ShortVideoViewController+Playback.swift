import AVFoundation
import AzureFishAPI
import UIKit

/// 管理当前页的播放资格、位置恢复及临时媒体访问。
extension ShortVideoViewController {
    func currentCell() -> ShortVideoCell? { feedView.list.cellForItem(at: IndexPath(item: viewModel.index, section: 0)) as? ShortVideoCell }
    func loadCurrent() {
        guard state.visible, state.foreground, !state.obscured, let item = current else { return }
        unload(); viewModel.errorKey = nil; feedView.loading.startAnimating()
        let token = state.generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.work { [self] in
                    // 封面失败不阻止视频；取消仍须传播。
                    do {
                        let (id, url) = try await runtime.media(item, thumbnail: true)
                        if state.accepts(token), let bytes = try? Data(contentsOf: url) { currentCell()?.poster.image = UIImage(data: bytes) }
                        await runtime.release(id)
                    } catch { try Task.checkCancellation() }
                    let (id, url) = try await runtime.media(item, thumbnail: false)
                    guard state.accepts(token), !Task.isCancelled else { await runtime.release(id); throw CancellationError() }
                    resource = id
                    audioActive = true
                    try await audio.activatePreviewPlayback()
                    guard state.accepts(token), !Task.isCancelled else { throw CancellationError() }
                    audioReady = true
                    let player = AVPlayer(url: url); player.isMuted = muted; player.allowsExternalPlayback = false
                    self.player = player; feedView.list.layoutIfNeeded(); currentCell()?.playerLayer.player = player
                    observation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
                        let ready = observedItem.status == .readyToPlay, failed = observedItem.status == .failed
                        Task { @MainActor [weak self] in
                            guard let self, state.accepts(token) else { return }
                            if ready {
                                feedView.loading.stopAnimating()
                                // 封面只在首帧前展示，横屏视频的留边应恢复为黑色画布。
                                currentCell()?.poster.image = nil
                                let duration = player.currentItem?.duration.seconds ?? 0
                                controlsView.seek.maximumValue = Float(duration.isFinite && duration > 0 ? duration : Double(item.duration))
                                controlsView.seek.value = 0; resume(token: token)
                            }
                            if failed { unload(); viewModel.errorKey = "shortVideo.failed" }
                            render()
                        }
                    }
                    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                        Task { @MainActor [weak self] in
                            guard let self, state.accepts(token), !controlsView.seek.isTracking else { return }; controlsView.seek.value = Float(time.seconds)
                        }
                    }
                    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, state.accepts(token) else { return }; positions[item.id] = 0
                            await player.seek(to: .zero); if state.canPlay && audioReady && state.accepts(token) { player.play() }
                        }
                    }
                }
            } catch is CancellationError {} catch {
                if state.generation == token { unload(); viewModel.errorKey = shortVideoErrorKey(error); render() }
            }
            if state.generation == token { loadTask = nil }
        }
    }
    /// 底部面板关闭后沿用同一帧；音频重新激活完成前不恢复播放。
    func restorePlayback() {
        guard state.visible, state.foreground, !state.obscured else { return }
        guard let player else { loadCurrent(); return }
        let token = state.generation, request = UUID()
        restoration = request
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if state.canPlay && !audioReady {
                    audioActive = true
                    try await audio.activatePreviewPlayback()
                }
                guard state.accepts(token), restoration == request, !Task.isCancelled else { return }
                if state.canPlay { audioReady = true }
                if player.currentItem?.status == .readyToPlay { currentCell()?.poster.image = nil }
                let duration = player.currentItem?.duration.seconds ?? 0
                if duration.isFinite && duration > 0 { controlsView.seek.maximumValue = Float(duration) }
                if state.canPlay { player.play() }
                render()
            } catch is CancellationError {} catch {
                if state.accepts(token), restoration == request { unload(); viewModel.errorKey = shortVideoErrorKey(error); render() }
            }
            if state.generation == token && restoration == request { loadTask = nil }
        }
    }
    func resume(token: UUID) {
        guard let player, let item = current else { return }
        let position = positions[item.id] ?? 0
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, state.accepts(token), state.canPlay, audioReady else { return }; player.play() }
        }
    }
    func unload() {
        if let item = current, let seconds = player?.currentTime().seconds, seconds.isFinite { positions[item.id] = seconds }
        state.invalidate(); restoration = UUID(); audioReady = false; loadTask?.cancel(); loadTask = nil; player?.pause()
        observation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }; timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        for cell in feedView.list.visibleCells.compactMap({ $0 as? ShortVideoCell }) { cell.playerLayer.player = nil; cell.poster.image = nil }
        player?.replaceCurrentItem(with: nil); player = nil
        if audioActive { audio.deactivate(); audioActive = false }
        if let resource { Task { [runtime] in await runtime.release(resource) } }; resource = nil
        feedView.loading.stopAnimating()
    }
    @objc func togglePlay() {
        state.paused.toggle()
        if player == nil { loadCurrent() } else if state.canPlay { restorePlayback() } else { player?.pause() }
        render()
    }
    func seekVideo() {
        guard let player else { return }; let token = state.generation
        player.seek(to: CMTime(seconds: Double(controlsView.seek.value), preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, state.accepts(token), state.canPlay, audioReady else { return }; player.play() }
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        state.scrolling = true
        // 已就绪的当前页冻结在原帧，回弹到同页时复用播放器；不提前加载相邻素材。
        if player?.currentItem?.status == .readyToPlay {
            player?.pause(); audioReady = false
            if audioActive { audio.deactivate(); audioActive = false }
        } else { unload() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settled() } }
    func settled() {
        guard feedView.list.bounds.height > 0, !viewModel.items.isEmpty else { return }
        let next = min(viewModel.items.count - 1, max(0, Int((feedView.list.contentOffset.y / feedView.list.bounds.height).rounded())))
        state.scrolling = false
        if next != viewModel.index {
            // 先按旧身份保存位置和释放媒体，再切换页面身份。
            unload(); viewModel.index = next; state.paused = false
            render(); loadCurrent()
        } else { restorePlayback(); render() }
        refreshCurrent()
        if viewModel.index >= viewModel.items.count - 2 && viewModel.more { viewModel.loadNextPage() }
    }
}
