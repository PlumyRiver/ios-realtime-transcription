//
//  TranscriptMessage.swift
//  ios_realtime_trans
//
//  Chirp3 語音轉錄與翻譯的資料模型
//

import Foundation

/// TTS 播放模式（四段切換）
/// - sourceOnly: 當「你」說話時播放 → 播放目標語言的翻譯
/// - targetOnly: 當「對方」說話時播放 → 播放來源語言的翻譯
enum TTSPlaybackMode: Int, CaseIterable {
    case all = 0          // 播放所有 TTS
    case sourceOnly = 1   // 只播放目標語言（當你說話時）
    case targetOnly = 2   // 只播放來源語言（當對方說話時）
    case muted = 3        // 靜音（不播放任何 TTS）

    /// 顯示名稱（用於設定頁面）
    var displayName: String {
        switch self {
        case .all: return "全部播放"
        case .sourceOnly: return "只播目標語言"
        case .targetOnly: return "只播來源語言"
        case .muted: return "靜音"
        }
    }

    /// 簡短名稱（靜態，用於無語言資訊時）
    var shortName: String {
        switch self {
        case .all: return "全部"
        case .sourceOnly: return "目標語言"
        case .targetOnly: return "來源語言"
        case .muted: return "靜音"
        }
    }

    /// 動態生成顯示名稱（帶具體語言）
    func displayText(sourceLang: Language, targetLang: Language) -> String {
        switch self {
        case .all: return "全部"
        case .sourceOnly: return "只播\(targetLang.shortName)"  // 播放目標語言
        case .targetOnly: return "只播\(sourceLang.shortName)"  // 播放來源語言
        case .muted: return "靜音"
        }
    }

    /// SF Symbol 圖標名稱
    var iconName: String {
        switch self {
        case .all: return "speaker.wave.3.fill"
        case .sourceOnly: return "speaker.wave.2.fill"
        case .targetOnly: return "speaker.wave.1.fill"
        case .muted: return "speaker.slash.fill"
        }
    }

    /// 切換到下一個模式
    func next() -> TTSPlaybackMode {
        let nextRawValue = (self.rawValue + 1) % TTSPlaybackMode.allCases.count
        return TTSPlaybackMode(rawValue: nextRawValue) ?? .all
    }
}

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

/// 延遲統計結構
struct LatencyInfo: Decodable {
    let transcriptMs: Int?      // 轉錄延遲（毫秒）
    let translationMs: Int?     // 翻譯延遲（毫秒）
}

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
    let latency: LatencyInfo?   // ⭐️ 延遲統計
}

/// 發送到 Server 的音頻訊息
struct AudioMessage: Encodable {
    let type: String = "audio"
    let data: String  // Base64 encoded audio data
}
