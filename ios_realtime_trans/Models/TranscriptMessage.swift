//
//  TranscriptMessage.swift
//  ios_realtime_trans
//
//  Chirp3 語音轉錄與翻譯的資料模型
//

import Foundation

/// 語言選項
enum Language: String, CaseIterable, Identifiable {
    case auto = "auto"
    case zh = "zh"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case es = "es"
    case fr = "fr"
    case de = "de"
    case it = "it"
    case pt = "pt"
    case ru = "ru"
    case ar = "ar"
    case hi = "hi"
    case th = "th"
    case vi = "vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "🌐 自動檢測"
        case .zh: return "🇹🇼 中文"
        case .en: return "🇺🇸 英文"
        case .ja: return "🇯🇵 日文"
        case .ko: return "🇰🇷 韓文"
        case .es: return "🇪🇸 西班牙文"
        case .fr: return "🇫🇷 法文"
        case .de: return "🇩🇪 德文"
        case .it: return "🇮🇹 義大利文"
        case .pt: return "🇵🇹 葡萄牙文"
        case .ru: return "🇷🇺 俄文"
        case .ar: return "🇸🇦 阿拉伯文"
        case .hi: return "🇮🇳 印地文"
        case .th: return "🇹🇭 泰文"
        case .vi: return "🇻🇳 越南文"
        }
    }

    var flag: String {
        switch self {
        case .auto: return "🌐"
        case .zh: return "🇹🇼"
        case .en: return "🇺🇸"
        case .ja: return "🇯🇵"
        case .ko: return "🇰🇷"
        case .es: return "🇪🇸"
        case .fr: return "🇫🇷"
        case .de: return "🇩🇪"
        case .it: return "🇮🇹"
        case .pt: return "🇵🇹"
        case .ru: return "🇷🇺"
        case .ar: return "🇸🇦"
        case .hi: return "🇮🇳"
        case .th: return "🇹🇭"
        case .vi: return "🇻🇳"
        }
    }

    /// 簡短名稱（用於底部控制欄）
    var shortName: String {
        switch self {
        case .auto: return "自動"
        case .zh: return "中文"
        case .en: return "英文"
        case .ja: return "日文"
        case .ko: return "韓文"
        case .es: return "西文"
        case .fr: return "法文"
        case .de: return "德文"
        case .it: return "義文"
        case .pt: return "葡文"
        case .ru: return "俄文"
        case .ar: return "阿文"
        case .hi: return "印地"
        case .th: return "泰文"
        case .vi: return "越文"
        }
    }
}

/// 轉錄訊息
struct TranscriptMessage: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let confidence: Double
    let language: String?
    let converted: Bool
    let originalText: String?
    let speakerTag: Int?
    let timestamp: Date
    var translation: String?

    init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool = false,
        confidence: Double = 0,
        language: String? = nil,
        converted: Bool = false,
        originalText: String? = nil,
        speakerTag: Int? = nil,
        timestamp: Date = Date(),
        translation: String? = nil
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.language = language
        self.converted = converted
        self.originalText = originalText
        self.speakerTag = speakerTag
        self.timestamp = timestamp
        self.translation = translation
    }

    /// 信心度等級
    var confidenceLevel: ConfidenceLevel {
        if confidence >= 0.85 {
            return .high
        } else if confidence >= 0.7 {
            return .medium
        } else {
            return .low
        }
    }

    enum ConfidenceLevel {
        case high, medium, low
    }
}

// MARK: - WebSocket 訊息解析

/// 從 Server 收到的轉錄訊息
struct ServerTranscriptResponse: Decodable {
    let type: String
    let text: String?
    let isFinal: Bool?
    let confidence: Double?
    let language: String?
    let converted: Bool?
    let originalText: String?
    let speakerTag: Int?
    let message: String?  // for error type
    let sourceText: String?
    let sourceLanguage: String?
    let targetLanguage: String?
}

/// 發送到 Server 的音頻訊息
struct AudioMessage: Encodable {
    let type: String = "audio"
    let data: String  // Base64 encoded audio data
}
