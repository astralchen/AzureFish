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

    @Test func systemEventUsesAppendOnlyFieldsAndSurvivesUnknownEnvelope() throws {
        var message = IMMessage()
        message.systemEvent.kind = "friendship_accepted"
        message.systemEvent.relationshipRevision = 2
        let bytes = try message.serializedData()
        #expect(Array(bytes.prefix(2)) == [0x92, 0x01]) // 字段 18，不改写原来的消息字段。
        var conversation = IMConversation()
        conversation.latestMessage = message
        #expect(try conversation.serializedData().first == 0x5a) // 字段 11。
        let legacy = try EmptyResponse(serializedBytes: bytes)
        #expect(try IMMessage(serializedBytes: legacy.serializedData()) == message)
    }

    @Test func mediaAppendOnlyFieldsAndUnknownEnvelopeRoundTrip() throws {
        var request = IMSendRequest(); request.assetIds = ["asset"]
        #expect(try request.serializedData().first == 0x4a) // 字段 9，保留原来的 1～8。
        var resource = MediaResource(); resource.resourceID = "resource"; resource.role = "original"
        resource.byteCount = 536_870_875; resource.sha256 = String(repeating: "a", count: 64)
        var asset = MediaAsset(); asset.assetID = "asset"; asset.kind = "file"; asset.resources = [resource]
        var message = IMMessage(); message.assets = [asset]
        #expect(try message.serializedData().first == 0x7a) // 字段 15，保留原来的 1～14。
        message.messageUuid = "message"; message.serverSeq = 42; message.contentType = "file"
        let unknown = try EmptyResponse(serializedBytes: message.serializedData())
        #expect(try IMMessage(serializedBytes: unknown.serializedData()) == message)
        var progress = MediaUploadProgress(); progress.role = "paired_video"; progress.completedParts = [0, 3, 7]
        #expect(try MediaUploadProgress(serializedBytes: progress.serializedData()) == progress)
    }

}
