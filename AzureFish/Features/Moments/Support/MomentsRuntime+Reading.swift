import Foundation
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage

extension MomentsRuntime {
    /// 恢复缓存快照并清理失去引用的文件，再按当前好友快照过滤展示内容。
    func restore() async throws {
        guard let store else { return }
        let posts = try await store.posts(), drafts = try await store.drafts(), pending = try await store.pending()
        let storedAlbums = try await store.albums()
        if let media { try await store.recoverCleanup(media: media) }
        try Task.checkCancellation()
        let allowed = chat.flatMap { $0.hasContactSnapshot ? Set($0.contacts.filter(\.canSend).map { $0.peer.id } + [userID]) : nil }
        for album in storedAlbums where allowed?.contains(album.owner.id) ?? true {
            if album.revision >= (albums[album.owner.id]?.revision ?? -1) { albums[album.owner.id] = album }
        }
        self.posts = filteredPosts(posts); self.drafts = drafts; self.pending = pending; notify()
    }
    /// 响应连接或好友版本变化，先撤回不可见内容，再清理缓存并刷新服务端状态。
    func contactsChanged() {
        if lastOffline != offline {
            lastOffline = offline; notify()
            if !offline { launch { [weak self] in try await self?.refresh() } }
        }
        guard let chat, chat.hasContactSnapshot else { return }
        let signature = Dictionary(uniqueKeysWithValues: chat.contacts.map { ($0.peer.id, $0.revision) })
        guard signature != contactSignature else { return }
        contactSignature = signature; refreshVersion = UUID()
        let filtered = filteredPosts(posts)
        let kept = Set(filtered.map(\.id)), removed = posts.filter { !kept.contains($0.id) }.map(\.id)
        posts = filtered
        let allowed = Set(chat.contacts.filter(\.canSend).map { $0.peer.id } + [userID])
        albums = albums.filter { allowed.contains($0.key) }; notify()
        launch { [weak self] in
            guard let self, let store else { return }
            try await store.removePosts(removed)
            for album in try await store.albums() where !allowed.contains(album.owner.id) { try await store.removeAuthor(album.owner.id) }
            try await store.merge(filtered)
            try await refresh()
        }
    }
    /// 按已取得的好友快照过滤作者和互动；尚无好友快照时保留输入。
    func filteredPosts(_ values: [MomentsPost]) -> [MomentsPost] {
        guard let chat, chat.hasContactSnapshot else { return values }
        let allowed = Set(chat.contacts.filter(\.canSend).map { $0.peer.id } + [userID])
        return values.filter { allowed.contains($0.author.id) }.map { value in
            guard value.author.id != userID else { return value }
            var value = value
            value.likes.removeAll { !allowed.contains($0.id) }
            value.comments.removeAll { !allowed.contains($0.author.id) || ($0.replyTo.map { !allowed.contains($0.id) } ?? false) }
            return value
        }
    }
    /// 刷新指定作者或主动态流；续页复用对应游标，普通刷新先校验缓存动态。
    ///
    /// 同时只执行一个请求；并发普通刷新排队保留最后一个作者，续页请求直接忽略。
    /// 普通刷新错误向调用方抛出，续页错误保存在 pageFailures 供显式重试。
    func refresh(author: String = "", next: Bool = false) async throws {
        guard let store else { return }
        guard !loading else { if !next { requestedAuthor = author }; return }
        guard let api else { failure = "moments.offline"; notify(); return }
        if next, more[author] == false || cursors[author] == nil { return }
        loading = true; loadingPageAuthor = next ? author : nil
        pageFailures[author] = nil; failure = nil; let version = refreshVersion, identity = epoch
        notify()
        defer {
            if identity == epoch {
                loading = false; loadingPageAuthor = nil; notify()
                if let requestedAuthor, self.store != nil {
                    self.requestedAuthor = nil
                    launch { [weak self] in try await self?.refresh(author: requestedAuthor) }
                }
            }
        }
        do {
            if !next {
                // 校验整个已缓存集合，防止翻页之外的旧内容在删除或失权后继续显示。
                let ids = posts.map(\.id)
                for start in stride(from: 0, to: ids.count, by: 100) {
                    let result = try await api.validate(Array(ids[start..<min(start + 100, ids.count)]))
                    try Task.checkCancellation(); guard refreshVersion == version else { return }
                    try await store.removePosts(result.unavailable); try await store.merge(result.posts)
                }
            }
            let page = try await api.list(author: author, cursor: next ? (cursors[author] ?? "") : "")
            // 写操作或好友变化会使旧请求失效，避免网络迟到结果覆盖新状态。
            try Task.checkCancellation(); guard refreshVersion == version else { return }
            // 拒绝无进展游标，避免短列表自动填充时连续请求同一页。
            if page.hasMore, page.cursor.isEmpty || (next && page.cursor == cursors[author]) { throw APIClientError.invalidResponse }
            try await store.merge(page.posts)
            let owner = author.isEmpty ? userID : author
            if !next {
                do {
                    let album = try await api.album(owner)
                    try Task.checkCancellation(); guard refreshVersion == version else { return }
                    try await store.save(album); albums[owner] = album
                } catch {
                    if isMomentUnavailable(error) { try await store.removeAuthor(owner); albums[owner] = nil }
                    else { throw error }
                }
            }
            try await restore()
            try Task.checkCancellation(); guard refreshVersion == version else { return }
            cursors[author] = page.cursor; more[author] = page.hasMore
        } catch {
            try Task.checkCancellation()
            guard refreshVersion == version else { return }
            if next { pageFailures[author] = momentsErrorKey(error) }
            else { throw error }
        }
    }

}
