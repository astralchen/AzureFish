//
//  SpeechConfiguration.swift
//  Demo
//

import Foundation

/// 媒体层支持的语音识别实现。
nonisolated enum SpeechBackend: Equatable, Sendable {
    /// 使用 iOS 26 的 Speech Analyzer 进行语音分析。
    case speechAnalyzer
    /// 使用 SFSpeechRecognizer 进行兼容语音识别。
    case speechRecognizer
}

/// 解析语音识别能力，而不向视图控制器暴露可用性检查。
@available(iOS 16.0, *)
nonisolated enum SpeechConfiguration {

    /// 返回指定能力对应的首选语音识别后端。
    ///
    /// - Parameter supportsSpeechAnalyzer: iOS 26 Speech Analyzer API 可用时为
    ///   `true`。
    /// - Returns: 支持时返回现代分析器后端；否则返回旧版语音识别器后端。
    static func preferredBackend(
        supportsSpeechAnalyzer: Bool
    ) -> SpeechBackend {
        supportsSpeechAnalyzer ? .speechAnalyzer : .speechRecognizer
    }

    /// 返回首选后端启动失败后可以尝试的兼容后端。
    ///
    /// 只有系统自动选择 `SpeechAnalyzer` 时允许回退。测试或调用方显式指定后端
    /// 时保持严格语义，便于验证单个实现的能力和错误。
    ///
    /// - Parameters:
    ///   - failedBackend: 本次未能启动的语音识别后端。
    ///   - wasExplicitlyRequested: 后端是否由调用方明确指定。
    /// - Returns: 可以继续尝试的后端；不应回退时为 `nil`。
    static func fallbackBackend(
        afterFailureOf failedBackend: SpeechBackend,
        wasExplicitlyRequested: Bool
    ) -> SpeechBackend? {
        guard failedBackend == .speechAnalyzer,
              !wasExplicitlyRequested else {
            return nil
        }
        return .speechRecognizer
    }

    /// 返回与应用区域设置对应的语音识别区域设置。
    ///
    /// Demo 支持英语、简体中文和阿拉伯语。带地区的识别区域设置可以让旧版识别器和
    /// iOS 26 资源解析器针对这些语言选项产生确定结果。
    ///
    /// - Parameter appLocale: 当前应用内本地化区域设置。
    /// - Returns: 适用于语音识别的区域设置。
    static func recognitionLocale(for appLocale: Locale) -> Locale {
        speechLocale(for: appLocale)
    }

    /// 返回与应用区域设置对应的语音处理区域设置。
    ///
    /// 此映射同时供语音识别和文本转语音使用，保证两条链路对 Demo 支持的语言
    /// 使用相同的地区变体。
    ///
    /// - Parameter appLocale: 当前应用内本地化区域设置。
    /// - Returns: 英语、简体中文或阿拉伯语对应的确定地区设置。
    static func speechLocale(for appLocale: Locale) -> Locale {
        let languageCode = appLocale.language.languageCode?.identifier
        switch languageCode {
        case "zh":
            return Locale(identifier: "zh-CN")
        case "ar":
            return Locale(identifier: "ar-SA")
        default:
            return Locale(identifier: "en-US")
        }
    }

    /// 返回可直接交给系统语音声线查询的 BCP 47 语言标签。
    ///
    /// `Locale.identifier` 在部分系统版本会使用下划线分隔语言与地区；
    /// `AVSpeechSynthesisVoice` 使用连字符形式的 BCP 47 标签进行匹配。
    ///
    /// - Parameter locale: 已完成地区映射的语音处理区域设置。
    /// - Returns: 使用连字符分隔的系统声线语言标签。
    static func speechVoiceLanguage(for locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-")
    }
}
