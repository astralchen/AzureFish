import AzureFishProtocol
import Foundation
import Testing

@Suite("插件生成协议")
struct ProtocolTests {
    @Test func shortSwiftNamesKeepWireNames() {
        #expect(RegisterRequest.protoMessageName == "azurefish.v1.RegisterRequest")
        #expect(AuthResponse.protoMessageName == "azurefish.v1.AuthResponse")
        #expect(UserProfile.protoMessageName == "azurefish.v1.UserProfile")
    }

    @Test func optionalPresenceAndInt64RoundTrip() throws {
        var message = UpdateProfileRequest()
        message.operationID = UUID().uuidString
        message.expectedProfileVersion = Int64.max
        message.bio = ""
        let decoded = try UpdateProfileRequest(serializedBytes: message.serializedData())
        #expect(decoded.hasBio && decoded.bio.isEmpty)
        #expect(!decoded.hasNickname)
        #expect(decoded.expectedProfileVersion == Int64.max)
    }

    @Test func unknownFieldsSurvive() throws {
        // 字段 99 的 varint=1，模拟服务端后续新增字段。
        let bytes = Data([0x98, 0x06, 0x01])
        let message = try EmptyResponse(serializedBytes: bytes)
        #expect(try message.serializedData() == bytes)
    }
}
