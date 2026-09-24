import AzureFishProtocol
import Foundation
import Testing

@Suite("服务端协议快照")
struct ProtocolTests {
    @Test func optionalPresenceAndInt64RoundTrip() throws {
        var message = Azurefish_V1_UpdateProfileRequest()
        message.operationID = UUID().uuidString
        message.expectedProfileVersion = Int64.max
        message.bio = ""
        let decoded = try Azurefish_V1_UpdateProfileRequest(serializedBytes: message.serializedData())
        #expect(decoded.hasBio && decoded.bio.isEmpty)
        #expect(!decoded.hasNickname)
        #expect(decoded.expectedProfileVersion == Int64.max)
    }

    @Test func unknownFieldsSurvive() throws {
        // 字段 99 的 varint=1，模拟服务端后续新增字段。
        let bytes = Data([0x98, 0x06, 0x01])
        let message = try Azurefish_V1_EmptyResponse(serializedBytes: bytes)
        #expect(try message.serializedData() == bytes)
    }
}
