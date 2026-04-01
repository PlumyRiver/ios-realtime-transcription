//
//  TranscriptMessage.swift
//  ios_realtime_trans
//
//  語音轉錄與翻譯的資料模型
//  支援 Google Chirp3 和 ElevenLabs Scribe v2 Realtime
//

import Foundation

/// ⭐️ STT 語言偵測模式
/// 控制 ElevenLabs 是否自動偵測語言或指定語言
enum STTLanguageDetectionMode: String, CaseIterable, Identifiable {
    case auto = "auto"               // 自動偵測（預設）
    case specifySource = "source"    // 指定來源語言
    case specifyTarget = "target"    // 指定目標語言

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自動偵測"
        case .specifySource: return "指定來源語言"
        case .specifyTarget: return "指定目標語言"
        }
    }

    var shortName: String {
        switch self {
        case .auto: return "自動"
        case .specifySource: return "來源"
        case .specifyTarget: return "目標"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "waveform.badge.magnifyingglass"
        case .specifySource: return "character.bubble"
        case .specifyTarget: return "person.wave.2"
        }
    }

    var description: String {
        switch self {
        case .auto: return "自動偵測說話的語言（可能被背景噪音干擾）"
        case .specifySource: return "只識別來源語言，適合單方向翻譯"
        case .specifyTarget: return "只識別目標語言，適合單方向翻譯"
        }
    }
}

/// STT 提供商
enum STTProvider: String, CaseIterable, Identifiable {
    case chirp3 = "chirp3"           // Google Cloud Chirp 3
    case elevenLabs = "elevenlabs"   // ElevenLabs Scribe v2 Realtime
    case apple = "apple"             // Apple 內建（設備端雙語言並行）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chirp3: return "Google Chirp 3"
        case .elevenLabs: return "ElevenLabs Scribe"
        case .apple: return "Apple 內建"
        }
    }

    var shortName: String {
        switch self {
        case .chirp3: return "Chirp3"
        case .elevenLabs: return "ElevenLabs"
        case .apple: return "Apple"
        }
    }

    var iconName: String {
        switch self {
        case .chirp3: return "waveform"
        case .elevenLabs: return "waveform.circle.fill"
        case .apple: return "apple.logo"
        }
    }

    /// 延遲特性說明
    var latencyDescription: String {
        switch self {
        case .chirp3: return "~300-500ms"
        case .elevenLabs: return "~150ms"
        case .apple: return "~100ms (本地)"
        }
    }

    /// 語言支援數量
    var languageCount: Int {
        switch self {
        case .chirp3: return 100
        case .elevenLabs: return 92
        case .apple: return 60  // 設備端支援約 60 種語言
        }
    }

    /// 是否免費
    var isFree: Bool {
        self == .apple
    }

    /// 是否需要網路（識別部分）
    var requiresNetwork: Bool {
        self != .apple  // Apple STT 可離線（設備端）
    }

    /// 特色說明
    var description: String {
        switch self {
        case .chirp3: return "高準確度，100+ 語言"
        case .elevenLabs: return "低延遲，自動 VAD"
        case .apple: return "免費離線，雙語並行"
        }
    }

    /// 識別模式說明
    var modeDescription: String {
        switch self {
        case .chirp3: return "串流識別，雲端處理"
        case .elevenLabs: return "串流識別 + VAD"
        case .apple: return "雙語並行，信心度選擇"
        }
    }
}

/// ⭐️ 翻譯模型提供商
enum TranslationProvider: String, CaseIterable, Identifiable {
    case gemini = "gemini"                     // Gemini 3 Flash（預設）
    case geminiFlashLite = "gemini-flash-lite"  // Gemini 3.1 Flash Lite（超值）
    case grok = "grok"                         // Grok 4.1 Fast（高品質）
    case cerebras = "cerebras"                 // Cerebras Llama（快速）
    case qwen = "qwen"                         // Qwen 3 235B（高品質+快速）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini 3 Flash"
        case .geminiFlashLite: return "Gemini 3.1 Flash Lite"
        case .grok: return "Grok 4.1 Fast"
        case .cerebras: return "Cerebras"
        case .qwen: return "Qwen 3 235B"
        }
    }

    var shortName: String {
        switch self {
        case .gemini: return "Gemini"
        case .geminiFlashLite: return "FlashLite"
        case .grok: return "Grok"
        case .cerebras: return "Cerebras"
        case .qwen: return "Qwen"
        }
    }

    var iconName: String {
        switch self {
        case .gemini: return "sparkles"
        case .geminiFlashLite: return "sparkle"
        case .grok: return "star.fill"
        case .cerebras: return "bolt.fill"
        case .qwen: return "brain.head.profile"
        }
    }

    /// 特色說明
    var description: String {
        switch self {
        case .gemini: return "預設，平衡"
        case .geminiFlashLite: return "超值，最便宜"
        case .grok: return "高品質翻譯"
        case .cerebras: return "極速回應"
        case .qwen: return "高品質+快速"
        }
    }

    /// 平均延遲
    var latencyDescription: String {
        switch self {
        case .gemini: return "~960ms"
        case .geminiFlashLite: return "~500ms"
        case .grok: return "~800ms"
        case .cerebras: return "~380ms"
        case .qwen: return "~460ms"
        }
    }

    /// 計費：輸入價格（每百萬 tokens，USD）
    var inputPricePerMillion: Double {
        switch self {
        case .gemini: return 0.50
        case .geminiFlashLite: return 0.075
        case .grok: return 0.20
        case .cerebras: return 0.85
        case .qwen: return 0.60
        }
    }

    /// 計費：輸出價格（每百萬 tokens，USD）
    var outputPricePerMillion: Double {
        switch self {
        case .gemini: return 3.00
        case .geminiFlashLite: return 0.30
        case .grok: return 0.50
        case .cerebras: return 1.20
        case .qwen: return 1.20
        }
    }

    /// 價格等級說明
    var priceLevel: String {
        switch self {
        case .gemini: return "$$"
        case .geminiFlashLite: return "¢"
        case .grok: return "$"
        case .cerebras: return "$$"
        case .qwen: return "$"
        }
    }

    /// 品質等級（1-5）
    var qualityRating: Int {
        switch self {
        case .gemini: return 4
        case .geminiFlashLite: return 3
        case .grok: return 5
        case .cerebras: return 3
        case .qwen: return 4
        }
    }
}

/// ⭐️ TTS 服務商
enum TTSProvider: String, CaseIterable, Identifiable {
    case azure = "azure"     // Azure 神經語音（高品質，付費）
    case apple = "apple"     // Apple 內建語音（免費，離線）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .azure: return "Azure 神經語音"
        case .apple: return "Apple 內建語音"
        }
    }

    var shortName: String {
        switch self {
        case .azure: return "Azure"
        case .apple: return "Apple"
        }
    }

    var iconName: String {
        switch self {
        case .azure: return "cloud.fill"
        case .apple: return "apple.logo"
        }
    }

    /// 特色說明
    var description: String {
        switch self {
        case .azure: return "高品質神經網路語音，需付費"
        case .apple: return "免費離線語音，品質一般"
        }
    }

    /// 是否免費
    var isFree: Bool {
        self == .apple
    }

    /// 是否需要網路
    var requiresNetwork: Bool {
        self == .azure
    }

    /// 延遲描述
    var latencyDescription: String {
        switch self {
        case .azure: return "~500ms (網路)"
        case .apple: return "~50ms (本地)"
        }
    }

    /// 品質等級（1-5）
    var qualityRating: Int {
        switch self {
        case .azure: return 5
        case .apple: return 3
        }
    }
}

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
/// 支援 ElevenLabs Scribe v2 (STT) 和 Azure TTS 共同支援的語言
/// 共 74 種語言（含自動檢測）
/// 排序：台灣常用 > 東南亞 > 東亞 > 南亞 > 中東 > 歐洲 > 非洲
enum Language: String, CaseIterable, Identifiable {
    case auto = "auto"

    // ===== 🔥 台灣人最常用 TOP 20 =====
    case zh = "zh"      // 中文
    case en = "en"      // 英文
    case ja = "ja"      // 日文
    case ko = "ko"      // 韓文
    case vi = "vi"      // 越南文
    case th = "th"      // 泰文
    case id = "id"      // 印尼文
    case fil = "fil"    // 菲律賓文
    case ms = "ms"      // 馬來文
    case my = "my"      // 緬甸文
    case km = "km"      // 高棉文（柬埔寨）
    case es = "es"      // 西班牙文
    case fr = "fr"      // 法文
    case de = "de"      // 德文
    case pt = "pt"      // 葡萄牙文
    case it = "it"      // 義大利文
    case ru = "ru"      // 俄文
    case ar = "ar"      // 阿拉伯文
    case tr = "tr"      // 土耳其文

    // ===== 🌏 東南亞 =====
    case lo = "lo"      // 老撾文
    case jv = "jv"      // 爪哇文
    case su = "su"      // 巽他文

    // ===== 🌸 東亞 =====
    // （中日韓已在 TOP 20）

    // ===== 🕌 南亞 =====
    case hi = "hi"      // 印地文
    case bn = "bn"      // 孟加拉文
    case ta = "ta"      // 塔米爾文
    case te = "te"      // 泰盧固文
    case mr = "mr"      // 馬拉地文
    case gu = "gu"      // 古吉拉特文
    case kn = "kn"      // 卡納達文
    case ml = "ml"      // 馬拉雅拉姆文
    case pa = "pa"      // 旁遮普文
    case ur = "ur"      // 烏爾都文
    case ne = "ne"      // 尼泊爾文

    // ===== 🏜️ 中東/中亞/高加索 =====
    case fa = "fa"      // 波斯文
    case he = "he"      // 希伯來文
    case hy = "hy"      // 亞美尼亞文
    case ka = "ka"      // 喬治亞文
    case az = "az"      // 阿塞拜疆文
    case kk = "kk"      // 哈薩克文

    // ===== 🏰 歐洲 - 西歐 =====
    case nl = "nl"      // 荷蘭文
    case ca = "ca"      // 加泰隆尼亞文
    case gl = "gl"      // 加利西亞文
    case eu = "eu"      // 巴斯克文
    case ga = "ga"      // 愛爾蘭文
    case cy = "cy"      // 威爾斯文

    // ===== 🏰 歐洲 - 北歐 =====
    case sv = "sv"      // 瑞典文
    case no = "no"      // 挪威文
    case da = "da"      // 丹麥文
    case fi = "fi"      // 芬蘭文
    case isLang = "is"  // 冰島文（is 是保留字）

    // ===== 🏰 歐洲 - 中歐 =====
    case pl = "pl"      // 波蘭文
    case cs = "cs"      // 捷克文
    case sk = "sk"      // 斯洛伐克文
    case hu = "hu"      // 匈牙利文

    // ===== 🏰 歐洲 - 東歐 =====
    case uk = "uk"      // 烏克蘭文
    case ro = "ro"      // 羅馬尼亞文
    case bg = "bg"      // 保加利亞文
    case lt = "lt"      // 立陶宛文
    case lv = "lv"      // 拉脫維亞文
    case et = "et"      // 愛沙尼亞文

    // ===== 🏰 歐洲 - 巴爾幹 =====
    case el = "el"      // 希臘文
    case hr = "hr"      // 克羅地亞文
    case sr = "sr"      // 塞爾維亞文
    case sl = "sl"      // 斯洛維尼亞文
    case bs = "bs"      // 波斯尼亞文
    case mk = "mk"      // 馬其頓文
    case sq = "sq"      // 阿爾巴尼亞文
    case mt = "mt"      // 馬耳他文

    // ===== 🌍 非洲 =====
    case sw = "sw"      // 斯瓦希里文
    case am = "am"      // 阿姆哈拉文
    case zu = "zu"      // 祖魯文
    case so = "so"      // 索馬里文

    var id: String { rawValue }

    var displayName: String {
        switch self {
        // 常用語言
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
        // 歐洲語言
        case .nl: return "🇳🇱 荷蘭文"
        case .pl: return "🇵🇱 波蘭文"
        case .tr: return "🇹🇷 土耳其文"
        case .sv: return "🇸🇪 瑞典文"
        case .cs: return "🇨🇿 捷克文"
        case .el: return "🇬🇷 希臘文"
        case .fi: return "🇫🇮 芬蘭文"
        case .ro: return "🇷🇴 羅馬尼亞文"
        case .da: return "🇩🇰 丹麥文"
        case .bg: return "🇧🇬 保加利亞文"
        case .sk: return "🇸🇰 斯洛伐克文"
        case .hr: return "🇭🇷 克羅地亞文"
        case .uk: return "🇺🇦 烏克蘭文"
        case .he: return "🇮🇱 希伯來文"
        case .hu: return "🇭🇺 匈牙利文"
        case .no: return "🇳🇴 挪威文"
        case .sl: return "🇸🇮 斯洛維尼亞文"
        case .sr: return "🇷🇸 塞爾維亞文"
        case .lt: return "🇱🇹 立陶宛文"
        case .lv: return "🇱🇻 拉脫維亞文"
        case .et: return "🇪🇪 愛沙尼亞文"
        case .bs: return "🇧🇦 波斯尼亞文"
        case .mk: return "🇲🇰 馬其頓文"
        case .sq: return "🇦🇱 阿爾巴尼亞文"
        case .mt: return "🇲🇹 馬耳他文"
        case .isLang: return "🇮🇸 冰島文"
        case .ga: return "🇮🇪 愛爾蘭文"
        case .cy: return "🏴󠁧󠁢󠁷󠁬󠁳󠁿 威爾斯文"
        case .ca: return "🇪🇸 加泰隆尼亞文"
        case .gl: return "🇪🇸 加利西亞文"
        case .eu: return "🇪🇸 巴斯克文"
        // 亞洲語言
        case .id: return "🇮🇩 印尼文"
        case .fil: return "🇵🇭 菲律賓文"
        case .ms: return "🇲🇾 馬來文"
        case .ta: return "🇮🇳 塔米爾文"
        case .bn: return "🇧🇩 孟加拉文"
        case .gu: return "🇮🇳 古吉拉特文"
        case .kn: return "🇮🇳 卡納達文"
        case .ml: return "🇮🇳 馬拉雅拉姆文"
        case .mr: return "🇮🇳 馬拉地文"
        case .ne: return "🇳🇵 尼泊爾文"
        case .pa: return "🇮🇳 旁遮普文"
        case .te: return "🇮🇳 泰盧固文"
        case .ur: return "🇵🇰 烏爾都文"
        case .fa: return "🇮🇷 波斯文"
        case .hy: return "🇦🇲 亞美尼亞文"
        case .ka: return "🇬🇪 喬治亞文"
        case .az: return "🇦🇿 阿塞拜疆文"
        case .kk: return "🇰🇿 哈薩克文"
        case .my: return "🇲🇲 緬甸文"
        case .km: return "🇰🇭 高棉文"
        case .lo: return "🇱🇦 老撾文"
        case .jv: return "🇮🇩 爪哇文"
        case .su: return "🇮🇩 巽他文"
        // 非洲語言
        case .sw: return "🇰🇪 斯瓦希里文"
        case .am: return "🇪🇹 阿姆哈拉文"
        case .zu: return "🇿🇦 祖魯文"
        case .so: return "🇸🇴 索馬里文"
        }
    }

    var flag: String {
        switch self {
        // 常用語言
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
        // 歐洲語言
        case .nl: return "🇳🇱"
        case .pl: return "🇵🇱"
        case .tr: return "🇹🇷"
        case .sv: return "🇸🇪"
        case .cs: return "🇨🇿"
        case .el: return "🇬🇷"
        case .fi: return "🇫🇮"
        case .ro: return "🇷🇴"
        case .da: return "🇩🇰"
        case .bg: return "🇧🇬"
        case .sk: return "🇸🇰"
        case .hr: return "🇭🇷"
        case .uk: return "🇺🇦"
        case .he: return "🇮🇱"
        case .hu: return "🇭🇺"
        case .no: return "🇳🇴"
        case .sl: return "🇸🇮"
        case .sr: return "🇷🇸"
        case .lt: return "🇱🇹"
        case .lv: return "🇱🇻"
        case .et: return "🇪🇪"
        case .bs: return "🇧🇦"
        case .mk: return "🇲🇰"
        case .sq: return "🇦🇱"
        case .mt: return "🇲🇹"
        case .isLang: return "🇮🇸"
        case .ga: return "🇮🇪"
        case .cy: return "🏴󠁧󠁢󠁷󠁬󠁳󠁿"
        case .ca: return "🇪🇸"
        case .gl: return "🇪🇸"
        case .eu: return "🇪🇸"
        // 亞洲語言
        case .id: return "🇮🇩"
        case .fil: return "🇵🇭"
        case .ms: return "🇲🇾"
        case .ta: return "🇮🇳"
        case .bn: return "🇧🇩"
        case .gu: return "🇮🇳"
        case .kn: return "🇮🇳"
        case .ml: return "🇮🇳"
        case .mr: return "🇮🇳"
        case .ne: return "🇳🇵"
        case .pa: return "🇮🇳"
        case .te: return "🇮🇳"
        case .ur: return "🇵🇰"
        case .fa: return "🇮🇷"
        case .hy: return "🇦🇲"
        case .ka: return "🇬🇪"
        case .az: return "🇦🇿"
        case .kk: return "🇰🇿"
        case .my: return "🇲🇲"
        case .km: return "🇰🇭"
        case .lo: return "🇱🇦"
        case .jv: return "🇮🇩"
        case .su: return "🇮🇩"
        // 非洲語言
        case .sw: return "🇰🇪"
        case .am: return "🇪🇹"
        case .zu: return "🇿🇦"
        case .so: return "🇸🇴"
        }
    }

    /// 簡短名稱（用於底部控制欄）
    var shortName: String {
        switch self {
        // 常用語言
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
        // 歐洲語言
        case .nl: return "荷蘭"
        case .pl: return "波蘭"
        case .tr: return "土耳其"
        case .sv: return "瑞典"
        case .cs: return "捷克"
        case .el: return "希臘"
        case .fi: return "芬蘭"
        case .ro: return "羅馬尼亞"
        case .da: return "丹麥"
        case .bg: return "保加利亞"
        case .sk: return "斯洛伐克"
        case .hr: return "克羅地亞"
        case .uk: return "烏克蘭"
        case .he: return "希伯來"
        case .hu: return "匈牙利"
        case .no: return "挪威"
        case .sl: return "斯洛維尼亞"
        case .sr: return "塞爾維亞"
        case .lt: return "立陶宛"
        case .lv: return "拉脫維亞"
        case .et: return "愛沙尼亞"
        case .bs: return "波斯尼亞"
        case .mk: return "馬其頓"
        case .sq: return "阿爾巴尼亞"
        case .mt: return "馬耳他"
        case .isLang: return "冰島"
        case .ga: return "愛爾蘭"
        case .cy: return "威爾斯"
        case .ca: return "加泰隆尼亞"
        case .gl: return "加利西亞"
        case .eu: return "巴斯克"
        // 亞洲語言
        case .id: return "印尼"
        case .fil: return "菲律賓"
        case .ms: return "馬來"
        case .ta: return "塔米爾"
        case .bn: return "孟加拉"
        case .gu: return "古吉拉特"
        case .kn: return "卡納達"
        case .ml: return "馬拉雅拉姆"
        case .mr: return "馬拉地"
        case .ne: return "尼泊爾"
        case .pa: return "旁遮普"
        case .te: return "泰盧固"
        case .ur: return "烏爾都"
        case .fa: return "波斯"
        case .hy: return "亞美尼亞"
        case .ka: return "喬治亞"
        case .az: return "阿塞拜疆"
        case .kk: return "哈薩克"
        case .my: return "緬甸"
        case .km: return "高棉"
        case .lo: return "老撾"
        case .jv: return "爪哇"
        case .su: return "巽他"
        // 非洲語言
        case .sw: return "斯瓦希里"
        case .am: return "阿姆哈拉"
        case .zu: return "祖魯"
        case .so: return "索馬里"
        }
    }

    /// Azure TTS 完整 locale 代碼
    /// 用於 Azure Speech Service 的語音合成
    var azureLocale: String {
        switch self {
        // 🔥 台灣常用 TOP 20
        case .auto: return "zh-TW"      // 預設台灣中文
        case .zh: return "zh-TW"        // 繁體中文-台灣
        case .en: return "en-US"        // 英文-美國
        case .ja: return "ja-JP"        // 日文-日本
        case .ko: return "ko-KR"        // 韓文-韓國
        case .vi: return "vi-VN"        // 越南文
        case .th: return "th-TH"        // 泰文
        case .id: return "id-ID"        // 印尼文
        case .fil: return "fil-PH"      // 菲律賓文
        case .ms: return "ms-MY"        // 馬來文
        case .my: return "my-MM"        // 緬甸文
        case .km: return "km-KH"        // 高棉文
        case .es: return "es-ES"        // 西班牙文-西班牙
        case .fr: return "fr-FR"        // 法文-法國
        case .de: return "de-DE"        // 德文-德國
        case .pt: return "pt-BR"        // 葡萄牙文-巴西
        case .it: return "it-IT"        // 義大利文
        case .ru: return "ru-RU"        // 俄文
        case .ar: return "ar-SA"        // 阿拉伯文-沙烏地
        case .tr: return "tr-TR"        // 土耳其文

        // 🌏 東南亞
        case .lo: return "lo-LA"        // 老撾文
        case .jv: return "jv-ID"        // 爪哇文
        case .su: return "su-ID"        // 巽他文

        // 🕌 南亞
        case .hi: return "hi-IN"        // 印地文
        case .bn: return "bn-IN"        // 孟加拉文-印度
        case .ta: return "ta-IN"        // 塔米爾文-印度
        case .te: return "te-IN"        // 泰盧固文
        case .mr: return "mr-IN"        // 馬拉地文
        case .gu: return "gu-IN"        // 古吉拉特文
        case .kn: return "kn-IN"        // 卡納達文
        case .ml: return "ml-IN"        // 馬拉雅拉姆文
        case .pa: return "pa-IN"        // 旁遮普文
        case .ur: return "ur-PK"        // 烏爾都文-巴基斯坦
        case .ne: return "ne-NP"        // 尼泊爾文

        // 🏜️ 中東/中亞/高加索
        case .fa: return "fa-IR"        // 波斯文
        case .he: return "he-IL"        // 希伯來文
        case .hy: return "hy-AM"        // 亞美尼亞文
        case .ka: return "ka-GE"        // 喬治亞文
        case .az: return "az-AZ"        // 阿塞拜疆文
        case .kk: return "kk-KZ"        // 哈薩克文

        // 🏰 歐洲 - 西歐
        case .nl: return "nl-NL"        // 荷蘭文
        case .ca: return "ca-ES"        // 加泰隆尼亞文
        case .gl: return "gl-ES"        // 加利西亞文
        case .eu: return "eu-ES"        // 巴斯克文
        case .ga: return "ga-IE"        // 愛爾蘭文
        case .cy: return "cy-GB"        // 威爾斯文

        // 🏰 歐洲 - 北歐
        case .sv: return "sv-SE"        // 瑞典文
        case .no: return "nb-NO"        // 挪威文（書面語）
        case .da: return "da-DK"        // 丹麥文
        case .fi: return "fi-FI"        // 芬蘭文
        case .isLang: return "is-IS"    // 冰島文

        // 🏰 歐洲 - 中歐
        case .pl: return "pl-PL"        // 波蘭文
        case .cs: return "cs-CZ"        // 捷克文
        case .sk: return "sk-SK"        // 斯洛伐克文
        case .hu: return "hu-HU"        // 匈牙利文

        // 🏰 歐洲 - 東歐
        case .uk: return "uk-UA"        // 烏克蘭文
        case .ro: return "ro-RO"        // 羅馬尼亞文
        case .bg: return "bg-BG"        // 保加利亞文
        case .lt: return "lt-LT"        // 立陶宛文
        case .lv: return "lv-LV"        // 拉脫維亞文
        case .et: return "et-EE"        // 愛沙尼亞文

        // 🏰 歐洲 - 巴爾幹
        case .el: return "el-GR"        // 希臘文
        case .hr: return "hr-HR"        // 克羅地亞文
        case .sr: return "sr-RS"        // 塞爾維亞文
        case .sl: return "sl-SI"        // 斯洛維尼亞文
        case .bs: return "bs-BA"        // 波斯尼亞文
        case .mk: return "mk-MK"        // 馬其頓文
        case .sq: return "sq-AL"        // 阿爾巴尼亞文
        case .mt: return "mt-MT"        // 馬耳他文

        // 🌍 非洲
        case .sw: return "sw-KE"        // 斯瓦希里文-肯亞
        case .am: return "am-ET"        // 阿姆哈拉文
        case .zu: return "zu-ZA"        // 祖魯文
        case .so: return "so-SO"        // 索馬里文
        }
    }
}

/// 翻譯分句結構
struct TranslationSegment: Identifiable, Equatable {
    let id: UUID
    let original: String      // 原文片段
    let translation: String   // 翻譯片段
    let isComplete: Bool      // 語義是否完整

    init(id: UUID = UUID(), original: String, translation: String, isComplete: Bool = true) {
        self.id = id
        self.original = original
        self.translation = translation
        self.isComplete = isComplete
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
    /// ⭐️ 是否為語言介紹提示（TTS 播放原文而非翻譯）
    let isIntroduction: Bool

    /// ⭐️ 分句翻譯結果（當有多個句子時使用）
    var translationSegments: [TranslationSegment]?

    /// ⭐️ 合併的翻譯文本（優先使用 translationSegments，否則使用 translation）
    var displayTranslation: String? {
        if let segments = translationSegments, !segments.isEmpty {
            return segments.map { $0.translation }.joined(separator: " ")
        }
        return translation
    }

    /// ⭐️ 是否有分句翻譯
    var hasSegmentedTranslation: Bool {
        guard let segments = translationSegments else { return false }
        return segments.count > 1
    }

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
        translation: String? = nil,
        translationSegments: [TranslationSegment]? = nil,
        isIntroduction: Bool = false
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
        self.translationSegments = translationSegments
        self.isIntroduction = isIntroduction
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
