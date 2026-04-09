//
//  AppleTTSService.swift
//  ios_realtime_trans
//
//  Apple 內建 TTS 服務（使用 AVSpeechSynthesizer）
//  優點：免費、離線可用、低延遲
//  缺點：語音品質不如 Azure 神經語音
//

import Foundation
import AVFoundation

/// Apple TTS 服務（使用系統內建語音合成）
class AppleTTSService: NSObject {

    // MARK: - Properties

    /// 語音合成器
    private let synthesizer = AVSpeechSynthesizer()

    /// 播放完成回調
    var onPlaybackFinished: (() -> Void)?

    /// 是否正在播放
    private(set) var isPlaying: Bool = false

    /// 是否已預熱（載入語音模型）
    private var isWarmedUp: Bool = false

    /// ⭐️ 是否正在「緩衝模式」（用 write() 渲染 PCM 由外部播放）
    /// 緩衝模式下要忽略 synthesizer 的 didStart/didFinish/didCancel 回調，
    /// 因為實際的播放完成是由外部（WebRTCAudioManager）通知，
    /// 不能讓 delegate 的 didFinish 提前觸發 onPlaybackFinished。
    private var isBufferedMode: Bool = false

    /// 當前播放的文本
    private(set) var currentText: String?

    /// 語速（0.0 ~ 1.0，預設 0.5）
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// 音調（0.5 ~ 2.0，預設 1.0）
    var pitchMultiplier: Float = 1.0

    /// 音量（0.0 ~ 1.0，預設 1.0）
    var volume: Float = 1.0

    // MARK: - Azure Locale 到 Apple Locale 映射
    // Azure 使用如 "zh-TW", "en-US" 格式，Apple 也支持但有些差異

    private let localeMapping: [String: String] = [
        // 直接支持的（Azure 和 Apple 格式相同）
        "zh-TW": "zh-TW",
        "zh-CN": "zh-CN",
        "zh-HK": "zh-HK",
        "en-US": "en-US",
        "en-GB": "en-GB",
        "ja-JP": "ja-JP",
        "ko-KR": "ko-KR",
        "es-ES": "es-ES",
        "fr-FR": "fr-FR",
        "de-DE": "de-DE",
        "it-IT": "it-IT",
        "pt-BR": "pt-BR",
        "ru-RU": "ru-RU",
        "ar-SA": "ar-SA",
        "hi-IN": "hi-IN",
        "th-TH": "th-TH",
        "vi-VN": "vi-VN",
        "id-ID": "id-ID",
        "ms-MY": "ms-MY",
        "nl-NL": "nl-NL",
        "pl-PL": "pl-PL",
        "tr-TR": "tr-TR",
        "uk-UA": "uk-UA",
        "cs-CZ": "cs-CZ",
        "ro-RO": "ro-RO",
        "hu-HU": "hu-HU",
        "el-GR": "el-GR",
        "sv-SE": "sv-SE",
        "da-DK": "da-DK",
        "fi-FI": "fi-FI",
        "nb-NO": "nb-NO",
        "sk-SK": "sk-SK",
        "he-IL": "he-IL",

        // 需要映射的（Azure 格式 → Apple 格式）
        "fil-PH": "fil-PH",  // 菲律賓語
        "bn-IN": "bn-IN",    // 孟加拉語
        "ta-IN": "ta-IN",    // 泰米爾語
        "te-IN": "te-IN",    // 泰盧固語
    ]

    // MARK: - Initialization

    override init() {
        super.init()
        synthesizer.delegate = self
        print("✅ [Apple TTS] 服務初始化完成")
    }

    // MARK: - Public Methods

    /// ⭐️ 緩衝模式：用 AVSpeechSynthesizer.write 把語音渲染成 PCM buffer，
    /// 由呼叫者（WebRTCAudioManager）透過 EQ 鏈播放，藉此實現音量增益。
    ///
    /// 為什麼要這樣？
    /// 直接呼叫 `speak()` 走系統音訊路徑，`utterance.volume` 上限只有 1.0，
    /// 無法達成 UI 標示的 +36 dB 增益。改用 `write()` 把音訊拿出來自己播放，
    /// 才能餵進 WebRTC TTS player → EQ → mainMixer 鏈，套用 3 頻段 EQ 增益。
    ///
    /// - Parameters:
    ///   - text: 要合成的文字
    ///   - languageCode: 語言代碼（Azure 格式，如 "zh-TW", "en-US"）
    ///   - bufferHandler: 每收到一段 PCM buffer 時呼叫（可能在合成器內部 queue 上呼叫，呼叫者需自行處理執行緒）
    ///   - completion: 合成器吐完所有 buffer 後呼叫（已切回主執行緒）
    func speakBuffered(
        text: String,
        languageCode: String = "zh-TW",
        bufferHandler: @escaping (AVAudioBuffer) -> Void,
        completion: @escaping () -> Void
    ) {
        stop()

        guard !text.isEmpty else {
            print("⚠️ [Apple TTS Buffered] 文字為空，跳過")
            DispatchQueue.main.async {
                completion()
            }
            return
        }

        currentText = text
        isPlaying = true
        isBufferedMode = true   // ⭐️ 進入緩衝模式，delegate 回調會被忽略

        let appleLocale = convertToAppleLocale(languageCode)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: appleLocale)
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        // 緩衝模式下保持原始音量，增益由 WebRTC EQ 處理
        utterance.volume = 1.0

        if utterance.voice == nil {
            print("⚠️ [Apple TTS Buffered] 找不到 \(appleLocale) 語音，使用預設")
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        }

        print("🎙️ [Apple TTS Buffered] 開始合成: \"\(text.prefix(30))...\"")
        print("   語言: \(appleLocale)")
        print("   語音: \(utterance.voice?.name ?? "預設")")

        var bufferCount = 0

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self = self else { return }

            // ⭐️ 空 buffer = 合成完成（write API 的約定）
            if let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength == 0 {
                print("✅ [Apple TTS Buffered] 合成完成（共 \(bufferCount) buffers）")
                DispatchQueue.main.async {
                    // ⭐️ 注意：isPlaying 由實際的播放完成回調控制（透過 completion）
                    //   而不是合成完成。合成快、播放慢，這兩個是不同事件。
                    completion()
                }
                return
            }

            bufferCount += 1
            bufferHandler(buffer)
        }
    }

    /// 合成並播放語音
    /// - Parameters:
    ///   - text: 要合成的文字
    ///   - languageCode: 語言代碼（Azure 格式，如 "zh-TW", "en-US"）
    func speak(text: String, languageCode: String = "zh-TW") {
        // 停止當前播放
        stop()

        guard !text.isEmpty else {
            print("⚠️ [Apple TTS] 文字為空，跳過")
            return
        }

        currentText = text
        isPlaying = true

        // 轉換語言代碼
        let appleLocale = convertToAppleLocale(languageCode)

        // 創建 utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: appleLocale)
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume

        // 如果找不到指定語言的語音，使用預設
        if utterance.voice == nil {
            print("⚠️ [Apple TTS] 找不到 \(appleLocale) 語音，使用預設")
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        }

        print("🎙️ [Apple TTS] 播放中: \"\(text.prefix(30))...\"")
        print("   語言: \(appleLocale)")
        print("   語音: \(utterance.voice?.name ?? "預設")")

        synthesizer.speak(utterance)
    }

    /// ⭐️ 預熱語音引擎（強制 iOS 載入語音模型，避免第一次播放卡頓）
    /// 在錄音開始時呼叫，靜音播放一個空格讓系統預載模型
    func preWarm(languageCode: String = "zh-TW") {
        guard !isWarmedUp else { return }
        isWarmedUp = true

        let appleLocale = convertToAppleLocale(languageCode)
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = AVSpeechSynthesisVoice(language: appleLocale)
        utterance.volume = 0  // 完全靜音
        synthesizer.speak(utterance)
        print("🔥 [Apple TTS] 預熱語音引擎: \(appleLocale)")
    }

    /// 停止播放
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            print("⏹️ [Apple TTS] 已停止")
        }
        isPlaying = false
        currentText = nil
        isBufferedMode = false   // ⭐️ 離開緩衝模式
    }

    /// 暫停播放
    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .immediate)
            print("⏸️ [Apple TTS] 已暫停")
        }
    }

    /// 繼續播放
    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            print("▶️ [Apple TTS] 繼續播放")
        }
    }

    // MARK: - Private Methods

    /// 轉換 Azure locale 到 Apple locale
    private func convertToAppleLocale(_ azureLocale: String) -> String {
        // 先查映射表
        if let appleLocale = localeMapping[azureLocale] {
            return appleLocale
        }

        // 嘗試直接使用（大部分 Azure 格式與 Apple 相容）
        if AVSpeechSynthesisVoice(language: azureLocale) != nil {
            return azureLocale
        }

        // 嘗試基礎語言代碼
        let baseLang = azureLocale.split(separator: "-").first.map(String.init) ?? azureLocale
        if AVSpeechSynthesisVoice(language: baseLang) != nil {
            print("⚠️ [Apple TTS] 使用基礎語言 \(baseLang) 替代 \(azureLocale)")
            return baseLang
        }

        // 預設使用繁體中文
        print("⚠️ [Apple TTS] 找不到 \(azureLocale) 語音，使用預設 zh-TW")
        return "zh-TW"
    }

    /// 獲取所有可用的語音列表（調試用）
    static func listAvailableVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        print("📋 [Apple TTS] 可用語音列表 (\(voices.count) 個):")
        for voice in voices {
            print("   \(voice.language): \(voice.name) (\(voice.quality.rawValue))")
        }
    }

    // MARK: - 語言支援檢查

    /// 檢查指定語言是否被 Apple TTS 支援
    /// - Parameter languageCode: Azure 格式的語言代碼（如 "zh-TW", "vi-VN"）
    /// - Returns: 是否支援
    static func isLanguageSupported(_ languageCode: String) -> Bool {
        // 直接檢查
        if AVSpeechSynthesisVoice(language: languageCode) != nil {
            return true
        }

        // 嘗試基礎語言代碼
        let baseLang = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        if AVSpeechSynthesisVoice(language: baseLang) != nil {
            return true
        }

        return false
    }

    /// 獲取不支援的語言列表（用於 UI 提示）
    static let unsupportedLanguages: Set<String> = [
        "ms-MY",   // 馬來語
        "fil-PH",  // 菲律賓語
        "my-MM",   // 緬甸語
        "km-KH",   // 高棉語
        "lo-LA",   // 寮語
        "bn-IN",   // 孟加拉語
        "ta-IN",   // 泰米爾語
        "te-IN",   // 泰盧固語
        "mr-IN",   // 馬拉地語
        "gu-IN",   // 古吉拉特語
        "kn-IN",   // 卡納達語
        "ml-IN",   // 馬拉雅拉姆語
        "pa-IN",   // 旁遮普語
        "si-LK",   // 僧伽羅語
        "ne-NP",   // 尼泊爾語
        "ur-PK",   // 烏爾都語
        "fa-IR",   // 波斯語
        "jv-ID",   // 爪哇語
        "su-ID",   // 巽他語
        "sw-KE",   // 斯瓦希里語
        "am-ET",   // 阿姆哈拉語
        "zu-ZA",   // 祖魯語
        "af-ZA",   // 南非語
        "az-AZ",   // 亞塞拜然語
        "kk-KZ",   // 哈薩克語
        "uz-UZ",   // 烏茲別克語
        "mn-MN",   // 蒙古語
        "ka-GE",   // 喬治亞語
        "hy-AM",   // 亞美尼亞語
    ]
}

// MARK: - AVSpeechSynthesizerDelegate

extension AppleTTSService: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // ⭐️ 緩衝模式下忽略：實際播放由 WebRTCAudioManager 控制
        guard !isBufferedMode else { return }
        print("▶️ [Apple TTS] 開始播放")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // ⭐️ 緩衝模式下忽略：完成事件由 speakBuffered 的 completion 處理
        guard !isBufferedMode else {
            print("✅ [Apple TTS Buffered] 合成器 didFinish（已忽略，等播放回調）")
            return
        }
        print("✅ [Apple TTS] 播放完成")
        // ⭐️ 確保在主線程更新狀態和調用回調（避免 UI 更新問題）
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.currentText = nil
            self?.onPlaybackFinished?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // ⭐️ 緩衝模式下忽略
        guard !isBufferedMode else { return }
        print("⏹️ [Apple TTS] 播放已取消")
        // ⭐️ 確保在主線程更新狀態
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.currentText = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        print("⏸️ [Apple TTS] 播放已暫停")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        print("▶️ [Apple TTS] 播放已繼續")
    }
}
