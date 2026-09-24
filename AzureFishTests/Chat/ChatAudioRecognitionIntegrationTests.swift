import OSLog
import AVFAudio
import Speech
import UIKit
import XCTest
@testable import AzureFish

private let logger = Logger(subsystem: "AzureFish.Tests", category: "ChatAudioRecognitionIntegrationTests")

/// 真实 SpeechTranscriber 验收；支持的真机自动准备中文模型，不使用兼容后端或模拟识别结果。
@MainActor
final class ChatAudioRecognitionIntegrationTests: XCTestCase {
    /// 安装中文模型后识别真实合成音频，并验证静音不会生成文字。
    func testChineseFileAndSilenceWithInstalledSystemModel() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Chat requires iOS 26 or later")
        }
        let locale = Locale(identifier: "zh-CN")
        recordEvidence("设备：\(UIDevice.current.name)，iOS \(UIDevice.current.systemVersion)，SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("当前真机/模拟器的 SpeechTranscriber.isAvailable=false，不能运行该识别后端")
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw XCTSkip("当前模拟器/设备不支持 SpeechTranscriber 中文文件识别")
        }
        try await AssetInventory.reserve(locale: supported)
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        let status = await AssetInventory.status(forModules: [module])
        recordEvidence("中文区域：\(supported.identifier)，模型初始状态：\(status)")
        guard status != .unsupported else {
            throw XCTSkip("当前设备不支持中文 SpeechTranscriber 模型：\(status)")
        }
        if status != .installed,
           let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installation.downloadAndInstall()
        }
        let installedStatus = await AssetInventory.status(forModules: [module])
        recordEvidence("中文模型准备后状态：\(installedStatus)")
        XCTAssertEqual(installedStatus, .installed, "模型未安装完成，不能开始真实识别验收")
        guard installedStatus == .installed else { return }
        let audioController = AudioController()
        defer { audioController.stopAll(); audioController.attachmentStore.removeAll() }
        let audio = try await audioController.synthesizeReplyAudio(text: "你好，你吃饭了吗？", locale: locale)
        let audioEvidence = XCTAttachment(contentsOfFile: audio.fileURL)
        audioEvidence.name = "chinese-speech-input.caf"
        audioEvidence.lifetime = .keepAlways
        add(audioEvidence)
        let service = AudioFileTranscriber(backend: .speechAnalyzer)
        let result = try await service.transcribe(fileURL: audio.fileURL, locale: locale)
        recordEvidence("SpeechTranscriber 中文音频识别结果：\(result ?? "nil")")
        XCTAssertTrue(result?.contains("你好") == true, "真实识别结果：\(result ?? "nil")")

        let silenceURL = audioController.attachmentStore.makeFileURL(prefix: "silence", pathExtension: "caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        if let samples = buffer.floatChannelData?[0] {
            samples.update(repeating: 0, count: Int(buffer.frameLength))
        }
        do {
            let file = try AVAudioFile(forWriting: silenceURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let silenceResult = try await service.transcribe(fileURL: silenceURL, locale: locale)
        recordEvidence("SpeechTranscriber 静音识别结果：\(silenceResult ?? "nil")")
        XCTAssertTrue(silenceResult?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
    }

    /// 将能力诊断、模型状态及识别原文写入日志和持久测试附件。
    private func recordEvidence(_ text: String) {
        logger.notice("[ChatSpeechIntegration] \(text, privacy: .public)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "SpeechTranscriber 真机证据"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
