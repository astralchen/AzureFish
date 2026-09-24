//
//  MediaFailure.swift
//  Demo
//

import Foundation

/// 媒体控制器向用户呈现的错误。
nonisolated enum MediaFailure: Equatable, Sendable {
    /// 用户未授予麦克风访问权限。
    case microphonePermissionDenied
    /// 用户未授予语音识别访问权限。
    case speechPermissionDenied
    /// 录音未达到允许保留和发送的最短时长。
    case recordingTooShort
    /// 录音无法开始或编码失败。
    case recordingFailed
    /// 音频文件不可读、无法解码或无法播放。
    case playbackFailed
    /// 当前语言或系统环境没有可用的语音识别服务。
    case speechUnavailable
    /// 语音识别启动或运行失败。
    case speechFailed
    /// 选定媒体无法复制或导入到页面目录。
    case mediaImportFailed
    /// 导入的媒体内容或元数据无效。
    case mediaInvalid
}
