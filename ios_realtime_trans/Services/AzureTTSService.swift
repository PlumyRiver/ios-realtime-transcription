//
//  AzureTTSService.swift
//  ios_realtime_trans
//
//  Azure Text-to-Speech 服務（WebSocket 串流版）
//  透過 Cloud Run 串流 TTS，即時接收音訊片段
//
//  ⚠️ 本檔只負責「合成」(synthesize) — 拿到 mp3 audioData 後就回傳。
//  播放交給 WebRTCAudioManager.playTTS(audioData:) 處理（共享 AEC 鏈路）。
//

import Foundation

/// Azure TTS 串流服務
class AzureTTSService {

    // WebSocket TTS 串流 URL
    private let streamURL = "wss://chirp3-ios-api-1027448899164.asia-east1.run.app/tts-stream"

    // WebSocket 連接
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// ⭐️ WebSocket 是否已連線
    private var isWebSocketConnected: Bool = false

    // 音訊片段累積（合成完成時透過 onComplete 一次回傳）
    private var audioChunks: [Data] = []
    private var isReceiving = false

    // 合成完成回調
    private var onComplete: ((Result<Data, Error>) -> Void)?

    // ⭐️ 語言特定語音映射（完整 73 種語言）
    // 使用 Azure locale code 作為 key，確保精確匹配
    private let voiceMapping: [String: [String: String]] = [
        // ===== 🔥 台灣人最常用 TOP 20 =====
        "zh-TW": ["male": "zh-TW-YunJheNeural", "female": "zh-TW-HsiaoChenNeural"],
        "en-US": ["male": "en-US-GuyNeural", "female": "en-US-JennyNeural"],
        "ja-JP": ["male": "ja-JP-KeitaNeural", "female": "ja-JP-NanamiNeural"],
        "ko-KR": ["male": "ko-KR-InJoonNeural", "female": "ko-KR-SunHiNeural"],
        "vi-VN": ["male": "vi-VN-NamMinhNeural", "female": "vi-VN-HoaiMyNeural"],
        "th-TH": ["male": "th-TH-NiwatNeural", "female": "th-TH-PremwadeeNeural"],
        "id-ID": ["male": "id-ID-ArdiNeural", "female": "id-ID-GadisNeural"],
        "fil-PH": ["male": "fil-PH-AngeloNeural", "female": "fil-PH-BlessicaNeural"],
        "ms-MY": ["male": "ms-MY-OsmanNeural", "female": "ms-MY-YasminNeural"],
        "my-MM": ["male": "my-MM-ThihaNeural", "female": "my-MM-NilarNeural"],
        "km-KH": ["male": "km-KH-PisethNeural", "female": "km-KH-SreymomNeural"],
        "es-ES": ["male": "es-ES-AlvaroNeural", "female": "es-ES-ElviraNeural"],
        "fr-FR": ["male": "fr-FR-HenriNeural", "female": "fr-FR-DeniseNeural"],
        "de-DE": ["male": "de-DE-ConradNeural", "female": "de-DE-KatjaNeural"],
        "pt-BR": ["male": "pt-BR-AntonioNeural", "female": "pt-BR-FranciscaNeural"],
        "it-IT": ["male": "it-IT-DiegoNeural", "female": "it-IT-ElsaNeural"],
        "ru-RU": ["male": "ru-RU-DmitryNeural", "female": "ru-RU-SvetlanaNeural"],
        "ar-SA": ["male": "ar-SA-HamedNeural", "female": "ar-SA-ZariyahNeural"],
        "tr-TR": ["male": "tr-TR-AhmetNeural", "female": "tr-TR-EmelNeural"],

        // ===== 🌏 東南亞 =====
        "lo-LA": ["male": "lo-LA-ChanthavongNeural", "female": "lo-LA-KeomanyNeural"],
        "jv-ID": ["male": "jv-ID-DimasNeural", "female": "jv-ID-SitiNeural"],
        "su-ID": ["male": "su-ID-JajangNeural", "female": "su-ID-TutiNeural"],

        // ===== 🌸 東亞 =====
        "zh-CN": ["male": "zh-CN-YunxiNeural", "female": "zh-CN-XiaoxiaoNeural"],
        "zh-HK": ["male": "zh-HK-WanLungNeural", "female": "zh-HK-HiuGaaiNeural"],

        // ===== 🕌 南亞 =====
        "hi-IN": ["male": "hi-IN-MadhurNeural", "female": "hi-IN-SwaraNeural"],
        "bn-IN": ["male": "bn-IN-BashkarNeural", "female": "bn-IN-TanishaaNeural"],
        "ta-IN": ["male": "ta-IN-ValluvarNeural", "female": "ta-IN-PallaviNeural"],
        "te-IN": ["male": "te-IN-MohanNeural", "female": "te-IN-ShrutiNeural"],
        "mr-IN": ["male": "mr-IN-ManoharNeural", "female": "mr-IN-AarohiNeural"],
        "gu-IN": ["male": "gu-IN-NiranjanNeural", "female": "gu-IN-DhwaniNeural"],
        "kn-IN": ["male": "kn-IN-GaganNeural", "female": "kn-IN-SapnaNeural"],
        "ml-IN": ["male": "ml-IN-MidhunNeural", "female": "ml-IN-SobhanaNeural"],
        "pa-IN": ["male": "pa-IN-GurpreetNeural", "female": "pa-IN-AmritaNeural"],  // ⚠️ 注意：Azure 可能用 pa-IN
        "si-LK": ["male": "si-LK-SameeraNeural", "female": "si-LK-ThiliniNeural"],
        "ne-NP": ["male": "ne-NP-SagarNeural", "female": "ne-NP-HemkalaNeural"],
        "ur-PK": ["male": "ur-PK-AsadNeural", "female": "ur-PK-UzmaNeural"],

        // ===== 🕌 中東 =====
        "fa-IR": ["male": "fa-IR-FaridNeural", "female": "fa-IR-DilaraNeural"],
        "he-IL": ["male": "he-IL-AvriNeural", "female": "he-IL-HilaNeural"],
        "ar-EG": ["male": "ar-EG-ShakirNeural", "female": "ar-EG-SalmaNeural"],

        // ===== 🇪🇺 歐洲 =====
        "nl-NL": ["male": "nl-NL-MaartenNeural", "female": "nl-NL-ColetteNeural"],
        "pl-PL": ["male": "pl-PL-MarekNeural", "female": "pl-PL-AgnieszkaNeural"],
        "uk-UA": ["male": "uk-UA-OstapNeural", "female": "uk-UA-PolinaNeural"],
        "cs-CZ": ["male": "cs-CZ-AntoninNeural", "female": "cs-CZ-VlastaNeural"],
        "ro-RO": ["male": "ro-RO-EmilNeural", "female": "ro-RO-AlinaNeural"],
        "hu-HU": ["male": "hu-HU-TamasNeural", "female": "hu-HU-NoemiNeural"],
        "el-GR": ["male": "el-GR-NestorasNeural", "female": "el-GR-AthinaNeural"],
        "sv-SE": ["male": "sv-SE-MattiasNeural", "female": "sv-SE-SofieNeural"],
        "da-DK": ["male": "da-DK-JeppeNeural", "female": "da-DK-ChristelNeural"],
        "fi-FI": ["male": "fi-FI-HarriNeural", "female": "fi-FI-NooraNeural"],
        "nb-NO": ["male": "nb-NO-FinnNeural", "female": "nb-NO-PernilleNeural"],
        "sk-SK": ["male": "sk-SK-LukasNeural", "female": "sk-SK-ViktoriaNeural"],
        "bg-BG": ["male": "bg-BG-BorislavNeural", "female": "bg-BG-KalinaNeural"],
        "hr-HR": ["male": "hr-HR-SreckoNeural", "female": "hr-HR-GabrijelaNeural"],
        "sl-SI": ["male": "sl-SI-RokNeural", "female": "sl-SI-PetraNeural"],
        "sr-RS": ["male": "sr-RS-NicholasNeural", "female": "sr-RS-SophieNeural"],
        "lt-LT": ["male": "lt-LT-LeonasNeural", "female": "lt-LT-OnaNeural"],
        "lv-LV": ["male": "lv-LV-NilsNeural", "female": "lv-LV-EveritaNeural"],
        "et-EE": ["male": "et-EE-KertNeural", "female": "et-EE-AnuNeural"],
        "is-IS": ["male": "is-IS-GunnarNeural", "female": "is-IS-GudrunNeural"],
        "mk-MK": ["male": "mk-MK-AleksandarNeural", "female": "mk-MK-MarijaNeural"],
        "mt-MT": ["male": "mt-MT-JosephNeural", "female": "mt-MT-GraceNeural"],
        "sq-AL": ["male": "sq-AL-IlirNeural", "female": "sq-AL-AnilaNeural"],
        "bs-BA": ["male": "bs-BA-GoranNeural", "female": "bs-BA-VesnaNeural"],
        "ca-ES": ["male": "ca-ES-EnricNeural", "female": "ca-ES-JoanaNeural"],
        "gl-ES": ["male": "gl-ES-RoiNeural", "female": "gl-ES-SabelaNeural"],
        "eu-ES": ["male": "eu-ES-AnderNeural", "female": "eu-ES-AinhoaNeural"],
        "cy-GB": ["male": "cy-GB-AledNeural", "female": "cy-GB-NiaNeural"],
        "ga-IE": ["male": "ga-IE-ColmNeural", "female": "ga-IE-OrlaNeural"],

        // ===== 🌍 非洲 =====
        "af-ZA": ["male": "af-ZA-WillemNeural", "female": "af-ZA-AdriNeural"],
        "sw-KE": ["male": "sw-KE-RafikiNeural", "female": "sw-KE-ZuriNeural"],
        "am-ET": ["male": "am-ET-AmehaNeural", "female": "am-ET-MekdesNeural"],
        "zu-ZA": ["male": "zu-ZA-ThembaNeural", "female": "zu-ZA-ThandoNeural"],

        // ===== 🌎 其他 =====
        "az-AZ": ["male": "az-AZ-BabekNeural", "female": "az-AZ-BanuNeural"],
        "kk-KZ": ["male": "kk-KZ-DauletNeural", "female": "kk-KZ-AigulNeural"],
        "uz-UZ": ["male": "uz-UZ-SardorNeural", "female": "uz-UZ-MadinaNeural"],
        "mn-MN": ["male": "mn-MN-BataaNeural", "female": "mn-MN-YesUINeural"],
        "ka-GE": ["male": "ka-GE-GiorgiNeural", "female": "ka-GE-EkaNeural"],
        "hy-AM": ["male": "hy-AM-HaykNeural", "female": "hy-AM-AnahitNeural"]
    ]

    /// 選擇合適的語音（根據完整 locale code）
    private func selectVoice(languageCode: String, gender: String = "female") -> String {
        // ⭐️ 直接使用完整 locale code 查找專用語音
        if let voices = voiceMapping[languageCode] {
            return voices[gender] ?? voices["female"]!
        }

        // 嘗試使用基礎語言代碼（如 "vi" → 找 "vi-VN"）
        let baseLang = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        for (locale, voices) in voiceMapping {
            if locale.hasPrefix(baseLang + "-") {
                print("⚠️ [TTS] 使用 \(locale) 語音替代 \(languageCode)")
                return voices[gender] ?? voices["female"]!
            }
        }

        // 預設使用中文台灣
        print("⚠️ [TTS] 找不到 \(languageCode) 語音，使用預設 zh-TW")
        return voiceMapping["zh-TW"]!["female"]!
    }


    /// ⭐️ 預先連接 WebSocket（在錄音開始時呼叫，預熱 Cloud Run）
    func preConnect() {
        guard webSocketTask == nil else { return }
        connectWebSocket()
        print("🔥 [TTS Stream] 預先連接 WebSocket（預熱 Cloud Run）")
    }

    /// 連接 WebSocket
    private func connectWebSocket() {
        // 斷開舊連線
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        guard let url = URL(string: streamURL) else {
            print("❌ [TTS Stream] Invalid URL")
            return
        }

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        isWebSocketConnected = true

        print("🔌 [TTS Stream] WebSocket connected")

        // 開始接收訊息
        receiveMessage()
    }

    /// 接收 WebSocket 訊息
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }

                // 繼續接收下一條訊息
                if self.isReceiving {
                    self.receiveMessage()
                }

            case .failure(let error):
                print("❌ [TTS Stream] WebSocket receive error: \(error)")
                self.onComplete?(.failure(error))
            }
        }
    }

    /// 處理收到的訊息
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "audio_chunk":
            if let base64Data = json["data"] as? String,
               let audioData = Data(base64Encoded: base64Data) {
                audioChunks.append(audioData)
                print("📦 [TTS Stream] Received chunk #\(audioChunks.count): \(audioData.count) bytes")
            }

        case "complete":
            isReceiving = false
            let totalChunks = json["totalChunks"] as? Int ?? 0
            let totalLatency = json["totalLatency"] as? Int ?? 0
            let firstByteLatency = json["firstByteLatency"] as? Int ?? 0

            print("✅ [TTS Stream] Complete: \(totalChunks) chunks, \(totalLatency)ms total, \(firstByteLatency)ms first byte")

            // 合併所有音訊片段
            let completeAudio = audioChunks.reduce(Data(), +)
            print("🎵 [TTS Stream] Total audio: \(completeAudio.count) bytes")

            // 回調成功
            onComplete?(.success(completeAudio))

            // 清理
            disconnectWebSocket()

        case "error":
            isReceiving = false
            let message = json["message"] as? String ?? "Unknown error"
            print("❌ [TTS Stream] Error: \(message)")

            onComplete?(.failure(TTSError.serverError(message)))
            disconnectWebSocket()

        default:
            break
        }
    }

    /// 斷開 WebSocket
    private func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        audioChunks.removeAll()
        onComplete = nil
    }

    /// 使用 Azure TTS 合成語音（WebSocket 串流版）
    /// - Parameters:
    ///   - text: 要合成的文字
    ///   - languageCode: 語言代碼（完整 Azure locale，如 "vi-VN", "zh-TW"）
    ///   - gender: 性別偏好 ("male" 或 "female")
    /// - Returns: 音頻數據
    func synthesize(text: String, languageCode: String = "zh-TW", gender: String = "female") async throws -> Data {
        guard !text.isEmpty else {
            throw TTSError.emptyText
        }

        // ⭐️ 記錄 TTS 用量（用於計費）
        BillingService.shared.recordTTSUsage(text: text)

        // ⭐️ 使用語言專用語音（不再使用多語言語音）
        let voice = selectVoice(languageCode: languageCode, gender: gender)

        print("🎙️ [TTS Stream] Synthesizing with voice: \(voice)")
        print("   Text: \(text.prefix(50))\(text.count > 50 ? "..." : "")")

        // 重置狀態
        audioChunks.removeAll()
        isReceiving = true

        // 連接 WebSocket（如果尚未連線或已斷線）
        if webSocketTask == nil || !isWebSocketConnected {
            connectWebSocket()
            // 等待新連接建立（僅新連線時）
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        }

        // 發送合成請求
        let request: [String: Any] = [
            "type": "synthesize",
            "text": text,
            "languageCode": languageCode,
            "voice": voice,
            "gender": gender
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw TTSError.invalidRequest
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("❌ [TTS Stream] Send error: \(error)")
            } else {
                print("📤 [TTS Stream] Request sent")
            }
        }

        // 等待合成完成
        return try await withCheckedThrowingContinuation { continuation in
            onComplete = { result in
                continuation.resume(with: result)
            }
        }
    }
}

// MARK: - Errors

enum TTSError: LocalizedError {
    case emptyText
    case invalidURL
    case invalidResponse
    case invalidRequest
    case httpError(Int)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "文字不能為空"
        case .invalidURL:
            return "無效的 URL"
        case .invalidResponse:
            return "無效的回應"
        case .invalidRequest:
            return "無效的請求"
        case .httpError(let code):
            return "HTTP 錯誤: \(code)"
        case .serverError(let message):
            return "伺服器錯誤: \(message)"
        }
    }
}
