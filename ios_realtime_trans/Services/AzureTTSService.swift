//
//  AzureTTSService.swift
//  ios_realtime_trans
//
//  Azure Text-to-Speech 服務（WebSocket 串流版）
//  透過 Cloud Run 串流 TTS，即時接收音訊片段
//

import Foundation
import AVFoundation

/// Azure TTS 串流服務
class AzureTTSService {

    // WebSocket TTS 串流 URL
    private let streamURL = "wss://chirp3-ios-api-1027448899164.asia-east1.run.app/tts-stream"

    // WebSocket 連接
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // 音訊片段累積
    private var audioChunks: [Data] = []
    private var isReceiving = false

    // 音頻播放器（使用 AVAudioEngine 來支持音量放大）
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?

    // ⭐️ 音量增益（可調整）
    // 1.0 = 正常音量
    // 2.0 = 2 倍音量
    // 3.0 = 3 倍音量（默認）
    // 建議範圍：1.0 ~ 5.0（太大會失真）
    var volumeBoost: Float = 3.0

    // 回調
    private var onComplete: ((Result<Data, Error>) -> Void)?

    // 多語言語音（支援 41+ 語言的自動檢測）
    private let multilingualVoices: [String: String] = [
        "male": "en-US-RyanMultilingualNeural",
        "female": "en-US-JennyMultilingualNeural"
    ]

    // 語言特定語音映射
    private let voiceMapping: [String: [String: String]] = [
        "zh": ["male": "zh-TW-YunJheNeural", "female": "zh-TW-HsiaoChenNeural"],
        "en": ["male": "en-US-GuyNeural", "female": "en-US-JennyNeural"],
        "ja": ["male": "ja-JP-KeitaNeural", "female": "ja-JP-NanamiNeural"],
        "ko": ["male": "ko-KR-InJoonNeural", "female": "ko-KR-SunHiNeural"],
        "es": ["male": "es-ES-AlvaroNeural", "female": "es-ES-ElviraNeural"],
        "fr": ["male": "fr-FR-HenriNeural", "female": "fr-FR-DeniseNeural"],
        "de": ["male": "de-DE-ConradNeural", "female": "de-DE-KatjaNeural"],
        "it": ["male": "it-IT-DiegoNeural", "female": "it-IT-ElsaNeural"],
        "pt": ["male": "pt-BR-AntonioNeural", "female": "pt-BR-FranciscaNeural"],
        "ru": ["male": "ru-RU-DmitryNeural", "female": "ru-RU-SvetlanaNeural"],
        "th": ["male": "th-TH-NiwatNeural", "female": "th-TH-PremwadeeNeural"],
        "vi": ["male": "vi-VN-NamMinhNeural", "female": "vi-VN-HoaiMyNeural"]
    ]

    /// 選擇合適的語音
    private func selectVoice(languageCode: String, gender: String = "female", useMultilingual: Bool = true) -> String {
        // 優先使用多語言自動檢測語音
        if useMultilingual {
            return multilingualVoices[gender] ?? multilingualVoices["female"]!
        }

        // 提取語言代碼（zh-TW → zh）
        let baseLang = languageCode.split(separator: "-").first.map(String.init) ?? languageCode

        // 回退到特定語言語音
        if let voices = voiceMapping[baseLang] {
            return voices[gender] ?? voices["female"]!
        }

        // 預設使用中文台灣
        return voiceMapping["zh"]![gender]!
    }


    /// 連接 WebSocket
    private func connectWebSocket() {
        guard let url = URL(string: streamURL) else {
            print("❌ [TTS Stream] Invalid URL")
            return
        }

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

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
    ///   - languageCode: 語言代碼
    ///   - gender: 性別偏好 ("male" 或 "female")
    ///   - useMultilingual: 是否使用多語言自動檢測
    /// - Returns: 音頻數據
    func synthesize(text: String, languageCode: String = "zh-TW", gender: String = "female", useMultilingual: Bool = true) async throws -> Data {
        guard !text.isEmpty else {
            throw TTSError.emptyText
        }

        let voice = selectVoice(languageCode: languageCode, gender: gender, useMultilingual: useMultilingual)

        print("🎙️ [TTS Stream] Synthesizing with voice: \(voice)")
        print("   Text: \(text.prefix(50))\(text.count > 50 ? "..." : "")")

        // 重置狀態
        audioChunks.removeAll()
        isReceiving = true

        // 連接 WebSocket
        connectWebSocket()

        // 等待連接建立（簡單延遲）
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

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

    /// 播放合成的語音（使用 AVAudioEngine 支持音量放大）
    /// - Parameter audioData: 音頻數據（MP3 格式）
    func play(audioData: Data) throws {
        // ⭐️ 確保 audio session 允許播放
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)

        // 停止舊的播放
        stop()

        // 1. 將音頻數據寫入臨時文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try audioData.write(to: tempURL)

        // 2. 創建 AVAudioFile
        audioFile = try AVAudioFile(forReading: tempURL)

        guard let audioFile = audioFile else {
            throw TTSError.serverError("Failed to create audio file")
        }

        // 3. 創建 AVAudioEngine 和 PlayerNode
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let audioEngine = audioEngine,
              let playerNode = playerNode else {
            throw TTSError.serverError("Failed to create audio engine")
        }

        // 4. 連接節點
        audioEngine.attach(playerNode)

        // ⭐️ 關鍵：使用 mixer 來放大音量
        let mixer = audioEngine.mainMixerNode
        audioEngine.connect(playerNode, to: mixer, format: audioFile.processingFormat)

        // ⭐️ 設置音量增益（使用可配置的 volumeBoost）
        mixer.outputVolume = volumeBoost

        // 5. 啟動引擎
        try audioEngine.start()

        // 6. 播放音頻
        playerNode.scheduleFile(audioFile, at: nil) {
            // 播放完成後清理
            DispatchQueue.main.async { [weak self] in
                self?.cleanupPlayback()
            }
        }
        playerNode.play()

        print("▶️ [Azure TTS] Playing audio (\(audioData.count) bytes, duration: \(audioFile.length / audioFile.processingFormat.sampleRate)s, volume boost: \(volumeBoost)x)")
    }

    /// 清理播放資源
    private func cleanupPlayback() {
        playerNode?.stop()
        audioEngine?.stop()

        // 刪除臨時文件
        if let audioFile = audioFile {
            try? FileManager.default.removeItem(at: audioFile.url)
        }

        playerNode = nil
        audioEngine = nil
        audioFile = nil
    }

    /// 停止播放
    func stop() {
        cleanupPlayback()
    }

    /// 是否正在播放
    var isPlaying: Bool {
        playerNode?.isPlaying ?? false
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
