import Crypto
import Foundation

/// 按环境和用途隔离数据库字段加密、查找摘要与请求指纹。
struct Cryptography: Sendable {
    let environment: String
    private let encryptionKey: SymmetricKey
    private let digestKey: SymmetricKey

    init(key: Data, environment: String) throws {
        guard key.count == 32 else { throw ConfigurationError.invalidKey }
        self.environment = environment
        let master = SymmetricKey(data: key)
        encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(environment.utf8), info: Data("fields-v1".utf8), outputByteCount: 32)
        digestKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(environment.utf8), info: Data("indexes-v1".utf8), outputByteCount: 32)
    }

    func digest(_ data: Data, purpose: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: aad(purpose) + data, using: digestKey)).base64EncodedString()
    }

    func seal(_ data: Data, context: String) throws -> String {
        try AES.GCM.seal(data, using: encryptionKey, authenticating: aad(context)).combined!.base64EncodedString()
    }

    func open(_ value: String, context: String) throws -> Data {
        guard let bytes = Data(base64Encoded: value) else { throw ConfigurationError.invalidCiphertext }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: encryptionKey, authenticating: aad(context))
    }

    private func aad(_ context: String) -> Data {
        var result = Data()
        for value in ["azurefish-v1", environment, context] {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    static func randomToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum ConfigurationError: Error {
    case invalidKey, invalidCiphertext, localDevelopmentOnly, missingConfiguration, invalidDataDirectory, databaseInUse, keyMismatch
}
