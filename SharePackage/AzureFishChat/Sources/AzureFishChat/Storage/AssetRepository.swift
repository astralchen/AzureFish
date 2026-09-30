import AzureFishAPI
import GRDB

/// 共享附件与资源映射；消息和摘要只保存有序引用。
enum AssetRepository {
    /// 以元数据版本和资产身份构造本地存储键，使同一资产的不同版本可独立引用。
    static func key(_ value: ChatAsset) -> String { String(value.version) + ":" + value.id }
    /// 在调用者事务中保存资产元数据、波形及有序资源引用，返回资产存储键。
    static func save(_ asset: ChatAsset, in db: Database) throws -> String {
        let key = key(asset)
        try AssetRecord(key: key, id: asset.id, kind: asset.kind, version: asset.version).upsert(db)
        try AssetGeometryRecord(assetKey: key, width: asset.width, height: asset.height,
            duration: asset.duration, animated: asset.animated).upsert(db)
        try AssetWaveRecord.filter(AssetWaveRecord.Columns.assetKey == key).deleteAll(db)
        for (position, value) in asset.waveform.enumerated() { try AssetWaveRecord(assetKey: key, position: position, value: value).insert(db) }
        try AssetResourceRecord.filter(AssetResourceRecord.Columns.assetKey == key).deleteAll(db)
        for (position, resource) in asset.resources.enumerated() {
            try saveResource(.init(id: resource.id, filename: resource.filename, mime: resource.mime,
                bytes: resource.bytes, sha256: resource.sha256), in: db)
            try AssetResourceRecord(assetKey: key, position: position, resourceID: resource.id, role: resource.role).insert(db)
        }
        return key
    }
    /// 写入资源元数据；已有相同身份时要求完整字节数和摘要不变，否则抛出 unavailable。
    static func saveResource(_ resource: ResourceRecord, in db: Database) throws {
        if let old = try ResourceRecord.fetchOne(db, key: resource.id) {
            guard old.bytes == resource.bytes, old.sha256 == resource.sha256 else { throw ChatStoreError.unavailable }
        }
        try resource.upsert(db)
    }
    /// 按存储键批量恢复资产及有序子记录；缺失资产不加入字典，已有资产缺少必要子记录时抛错。
    static func fetch(_ keys: [String], in db: Database) throws -> [String: ChatAsset] {
        guard !keys.isEmpty else { return [:] }
        let assets = try AssetRecord.filter(keys.contains(AssetRecord.Columns.key)).fetchAll(db)
        let geometry = Dictionary(uniqueKeysWithValues: try AssetGeometryRecord.filter(keys.contains(AssetGeometryRecord.Columns.assetKey)).fetchAll(db).map { ($0.assetKey, $0) })
        let waves = Dictionary(grouping: try AssetWaveRecord.filter(keys.contains(AssetWaveRecord.Columns.assetKey)).order(AssetWaveRecord.Columns.position).fetchAll(db), by: \.assetKey)
        let links = try AssetResourceRecord.filter(keys.contains(AssetResourceRecord.Columns.assetKey)).order(AssetResourceRecord.Columns.position).fetchAll(db)
        let ids = links.map(\.resourceID)
        let resources = Dictionary(uniqueKeysWithValues: try ResourceRecord.filter(ids.contains(ResourceRecord.Columns.id)).fetchAll(db).map { ($0.id, $0) })
        let grouped = Dictionary(grouping: links, by: \.assetKey)
        return try Dictionary(uniqueKeysWithValues: assets.map { asset in
            guard let geometry = geometry[asset.key] else { throw ChatStoreError.unavailable }
            let values: [ChatResource] = try (grouped[asset.key] ?? []).map { link in
                guard let row = resources[link.resourceID] else { throw ChatStoreError.unavailable }
                return .init(id: row.id, role: link.role, filename: row.filename, mime: row.mime, bytes: row.bytes, sha256: row.sha256)
            }
            return (asset.key, ChatAsset(id: asset.id, kind: asset.kind, resources: values, width: geometry.width,
                height: geometry.height, duration: geometry.duration, animated: geometry.animated,
                waveform: (waves[asset.key] ?? []).map(\.value), version: asset.version))
        })
    }
}
