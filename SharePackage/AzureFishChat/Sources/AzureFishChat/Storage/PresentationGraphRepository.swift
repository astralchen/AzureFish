import Foundation
import AzureFishAPI
import GRDB

/// 类型化编辑器图映射；调用者负责根记录及外层事务。
enum PresentationGraphRepository {
    /// 删除指定所有者的派生展示片段及附件子记录；调用方负责根记录、事务及资源清理登记。
    static func clear(_ owner: String, in db: Database) throws {
        try PresentationSegmentRecord.filter(PresentationSegmentRecord.Columns.ownerID == owner).deleteAll(db)
        try PresentationSegmentRunRecord.filter(PresentationSegmentRunRecord.Columns.ownerID == owner).deleteAll(db)
        try PresentationAttachmentRecord.filter(PresentationAttachmentRecord.Columns.ownerID == owner).deleteAll(db)
        try PresentationMediaItemRecord.filter(PresentationMediaItemRecord.Columns.ownerID == owner).deleteAll(db)
        try PresentationWaveRecord.filter(PresentationWaveRecord.Columns.ownerID == owner).deleteAll(db)
    }
    /// 在调用者事务中替换派生展示子记录，按原顺序保存片段、附件、媒体条目和波形。
    static func save(_ value: StoredChatDraft, owner: String, in db: Database) throws {
        try clear(owner, in: db)
        for (position, segment) in value.segments.enumerated() {
            let kind: String, text: String?, attachment: String?
            switch segment {
            case .text(let value): kind = "text"; text = value; attachment = nil
            case .attachment(let id): kind = "attachment"; text = nil; attachment = id.uuidString
            case .richText(let runs):
                kind = "richText"; text = nil; attachment = nil
                for (index, run) in runs.enumerated() {
                    try PresentationSegmentRunRecord(ownerID: owner, segmentPosition: position, position: index, text: run.text, style: run.style).insert(db)
                }
            }
            try PresentationSegmentRecord(ownerID: owner, position: position, kind: kind, text: text, attachmentID: attachment).insert(db)
        }
        var attachments = value.documents.map { ("document", $0) }
        if let media = value.media { attachments.append(("media", .mediaGroup(media))) }
        if let audio = value.audio { attachments.append(("audio", .audio(audio))) }
        for (position, pair) in attachments.enumerated() {
            let (slot, attachment) = pair
            var row = PresentationAttachmentRecord(ownerID: owner, position: position, slot: slot, id: attachment.id.uuidString,
                kind: "", resourceID: nil, thumbnailID: nil, iconID: nil, filename: nil, typeIdentifier: nil,
                byteCount: nil, url: nil, title: nil, duration: nil, transcript: nil)
            switch attachment {
            case .file(let file):
                row.kind = "file"; row.resourceID = file.resourceID.uuidString; row.thumbnailID = file.thumbnailID?.uuidString
                row.filename = file.displayName; row.typeIdentifier = file.typeIdentifier; row.byteCount = file.byteCount
            case .link(let link):
                row.kind = "link"; row.url = link.url; row.title = link.title
                row.thumbnailID = link.imageID?.uuidString; row.iconID = link.iconID?.uuidString
            case .audio(let audio):
                row.kind = "audio"; row.resourceID = audio.resourceID.uuidString; row.duration = audio.duration; row.transcript = audio.transcript
                for (index, value) in audio.waveform.enumerated() {
                    try PresentationWaveRecord(ownerID: owner, attachmentPosition: position, position: index, value: value).insert(db)
                }
            case .mediaGroup(let group):
                row.kind = "mediaGroup"
                for (index, item) in group.items.enumerated() {
                    try PresentationMediaItemRecord(ownerID: owner, attachmentPosition: position, position: index, id: item.id.uuidString,
                        assetIdentifier: item.assetIdentifier, originalID: item.originalID.uuidString, thumbnailID: item.thumbnailID.uuidString,
                        pairedVideoID: item.pairedVideoID?.uuidString, width: item.width, height: item.height,
                        duration: item.duration, animated: item.animated).insert(db)
                }
            }
            try row.insert(db)
        }
    }
    /// 批量恢复指定所有者的派生展示结构，按位置还原集合；无效 UUID、种类或必要字段缺失时抛错。
    static func fetch(_ owners: [String], in db: Database) throws -> [String: StoredChatDraft] {
        guard !owners.isEmpty else { return [:] }
        let segments = Dictionary(grouping: try PresentationSegmentRecord.filter(owners.contains(PresentationSegmentRecord.Columns.ownerID)).order(PresentationSegmentRecord.Columns.position).fetchAll(db), by: \.ownerID)
        let runs = Dictionary(grouping: try PresentationSegmentRunRecord.filter(owners.contains(PresentationSegmentRunRecord.Columns.ownerID)).order(PresentationSegmentRunRecord.Columns.position).fetchAll(db), by: \.ownerID)
        let attachments = Dictionary(grouping: try PresentationAttachmentRecord.filter(owners.contains(PresentationAttachmentRecord.Columns.ownerID)).order(PresentationAttachmentRecord.Columns.position).fetchAll(db), by: \.ownerID)
        let items = Dictionary(grouping: try PresentationMediaItemRecord.filter(owners.contains(PresentationMediaItemRecord.Columns.ownerID)).order(PresentationMediaItemRecord.Columns.position).fetchAll(db), by: \.ownerID)
        let waves = Dictionary(grouping: try PresentationWaveRecord.filter(owners.contains(PresentationWaveRecord.Columns.ownerID)).order(PresentationWaveRecord.Columns.position).fetchAll(db), by: \.ownerID)
        var result: [String: StoredChatDraft] = [:]
        for owner in owners {
            var value = StoredChatDraft(conversationID: owner)
            value.segments = try (segments[owner] ?? []).map { row in
                switch row.kind {
                case "text": guard let text = row.text else { throw ChatStoreError.unavailable }; return .text(text)
                case "attachment": return .attachment(try storageUUID(row.attachmentID))
                case "richText": return .richText((runs[owner] ?? []).filter { $0.segmentPosition == row.position }.map { .init(text: $0.text, style: $0.style) })
                default: throw ChatStoreError.unavailable
                }
            }
            for row in attachments[owner] ?? [] {
                let id = try storageUUID(row.id), attachment: StoredDraftAttachment
                switch row.kind {
                case "file":
                    guard let name = row.filename, let type = row.typeIdentifier, let bytes = row.byteCount else { throw ChatStoreError.unavailable }
                    attachment = .file(.init(id: id, resourceID: try storageUUID(row.resourceID), displayName: name,
                        typeIdentifier: type, byteCount: bytes, thumbnailID: try row.thumbnailID.map { try storageUUID($0) }))
                case "link":
                    guard let url = row.url else { throw ChatStoreError.unavailable }
                    attachment = .link(.init(id: id, url: url, title: row.title,
                        imageID: try row.thumbnailID.map { try storageUUID($0) }, iconID: try row.iconID.map { try storageUUID($0) }))
                case "audio":
                    guard let duration = row.duration else { throw ChatStoreError.unavailable }
                    attachment = .audio(.init(id: id, resourceID: try storageUUID(row.resourceID), duration: duration,
                        waveform: (waves[owner] ?? []).filter { $0.attachmentPosition == row.position }.map(\.value), transcript: row.transcript))
                case "mediaGroup":
                    let media: [StoredDraftMediaItem] = try (items[owner] ?? []).filter { $0.attachmentPosition == row.position }.map {
                        .init(id: try storageUUID($0.id), assetIdentifier: $0.assetIdentifier,
                            originalID: try storageUUID($0.originalID), thumbnailID: try storageUUID($0.thumbnailID),
                            pairedVideoID: try $0.pairedVideoID.map { try storageUUID($0) }, width: $0.width, height: $0.height,
                            duration: $0.duration, animated: $0.animated)
                    }
                    attachment = .mediaGroup(.init(id: id, items: media))
                default: throw ChatStoreError.unavailable
                }
                switch (row.slot, attachment) {
                case ("document", _): value.documents.append(attachment)
                case ("media", .mediaGroup(let group)): value.media = group
                case ("audio", .audio(let audio)): value.audio = audio
                default: throw ChatStoreError.unavailable
                }
            }
            result[owner] = value
        }
        return result
    }
}
