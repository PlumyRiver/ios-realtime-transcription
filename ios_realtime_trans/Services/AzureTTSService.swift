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
    private var eqNode: AVAudioUnitEQ?
    private var audioFile: AVAudioFile?

    // ⭐️ 音量增益（dB）
    // 0 dB = 正常音量
    // +6 dB ≈ 2 倍音量
    // +12 dB ≈ 4 倍音量
    // +18 dB ≈ 8 倍音量
    // +24 dB ≈ 16 倍音量（默認 - 非常大聲）
    // 建議範圍：0 ~ 40 dB
    var volumeBoostDB: Float = 24.0

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

    /// 直接放大 PCM buffer 的音量（修改樣本值）
    /// - Parameters:
    ///   - buffer: 要放大的音頻 buffer
    ///   - gain: 增益倍數
    private func amplifyBuffer(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let format = buffer.format

        print("📊 [Buffer Format] Channels: \(channelCount), Frames: \(frameLength)")
        print("📊 [Buffer Format] Sample rate: \(format.sampleRate)Hz, IsFloat: \(format.commonFormat == .pcmFormatFloat32)")
        print("📊 [Buffer Format] CommonFormat: \(format.commonFormat.rawValue)")

        // 檢查原始樣本值（前 10 個）
        if let floatData = buffer.floatChannelData {
            let samples = floatData[0]
            var maxSample: Float = 0
            for i in 0..<min(10, Int(frameLength)) {
                maxSample = max(maxSample, abs(samples[i]))
                if i < 3 {
                    print("📊 [Original Sample \(i)] \(samples[i])")
                }
            }
            print("📊 [Original Max] \(maxSample)")
        } else if let int16Data = buffer.int16ChannelData {
            let samples = int16Data[0]
            var maxSample: Int16 = 0
            for i in 0..<min(10, Int(frameLength)) {
                maxSample = max(maxSample, abs(samples[i]))
                if i < 3 {
                    print("📊 [Original Sample \(i)] \(samples[i])")
                }
            }
            print("📊 [Original Max] \(maxSample)")
        } else {
            print("❌ [Buffer Amplify] FAILED - No accessible channel data!")
            return nil
        }

        // 嘗試 Float 格式放大
        if let floatChannelData = buffer.floatChannelData {
            print("✅ [Buffer Amplify] Using FLOAT format")

            for channel in 0..<channelCount {
                let samples = floatChannelData[channel]
                for frame in 0..<frameLength {
                    let original = samples[frame]
                    let amplified = original * gain
                    // 硬限制防止削波
                    samples[frame] = min(max(amplified, -1.0), 1.0)
                }
            }

            // 檢查放大後的樣本值
            let samples = floatChannelData[0]
            var maxAmplified: Float = 0
            for i in 0..<min(10, Int(frameLength)) {
                maxAmplified = max(maxAmplified, abs(samples[i]))
                if i < 3 {
                    print("📊 [Amplified Sample \(i)] \(samples[i])")
                }
            }
            print("📊 [Amplified Max] \(maxAmplified)")
            print("🔊 [Buffer Amplify] Successfully amplified \(frameLength) frames × \(channelCount) channels with gain \(gain)x")

            return buffer
        }

        // 嘗試 Int16 格式放大（需要轉換）
        if let int16ChannelData = buffer.int16ChannelData {
            print("⚠️ [Buffer Amplify] Using INT16 format - need conversion")

            // 創建 Float 格式的 buffer
            let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: format.sampleRate,
                                           channels: format.channelCount,
                                           interleaved: false)!

            guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: buffer.frameCapacity) else {
                print("❌ [Buffer Amplify] Failed to create float buffer")
                return nil
            }

            floatBuffer.frameLength = buffer.frameLength

            // 轉換 Int16 → Float 並放大
            guard let floatData = floatBuffer.floatChannelData else {
                print("❌ [Buffer Amplify] No float channel data in new buffer")
                return nil
            }

            for channel in 0..<channelCount {
                let int16Samples = int16ChannelData[channel]
                let floatSamples = floatData[channel]

                for frame in 0..<frameLength {
                    // Int16 → Float: 除以 32768.0
                    let floatValue = Float(int16Samples[frame]) / 32768.0
                    // 放大並限制
                    floatSamples[frame] = min(max(floatValue * gain, -1.0), 1.0)
                }
            }

            // 檢查放大後的樣本值
            let samples = floatData[0]
            var maxAmplified: Float = 0
            for i in 0..<min(10, Int(frameLength)) {
                maxAmplified = max(maxAmplified, abs(samples[i]))
                if i < 3 {
                    print("📊 [Amplified Sample \(i)] \(samples[i])")
                }
            }
            print("📊 [Amplified Max] \(maxAmplified)")
            print("🔊 [Buffer Amplify] Converted and amplified \(frameLength) frames × \(channelCount) channels with gain \(gain)x")

            return floatBuffer
        }

        print("❌ [Buffer Amplify] Unsupported buffer format!")
        return nil
    }

    /// 播放合成的語音（使用 AVAudioUnitEQ 支持音量放大）
    /// - Parameter audioData: 音頻數據（MP3 格式）
    func play(audioData: Data) throws {
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

        print("📦 [Azure TTS] Audio file length: \(audioFile.length) frames")
        print("📦 [Azure TTS] Format: \(audioFile.processingFormat)")

        // 3. 創建 AVAudioEngine、PlayerNode 和 EQ
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        // ⭐️ 關鍵：創建 AVAudioUnitEQ 用於音量放大
        eqNode = AVAudioUnitEQ(numberOfBands: 0)  // 0 bands = 只使用 globalGain

        guard let audioEngine = audioEngine,
              let playerNode = playerNode,
              let eqNode = eqNode else {
            throw TTSError.serverError("Failed to create audio engine")
        }

        // 4. 連接節點：PlayerNode → EQ → MainMixerNode → Output
        audioEngine.attach(playerNode)
        audioEngine.attach(eqNode)

        let format = audioFile.processingFormat
        audioEngine.connect(playerNode, to: eqNode, format: format)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: format)

        // ⭐️ 設置 EQ 的 globalGain（這個方法在錄音時也有效！）
        eqNode.globalGain = volumeBoostDB
        print("🔊 [Audio EQ] Global gain set to \(volumeBoostDB) dB")

        // 5. 啟動引擎
        try audioEngine.start()
        print("🎵 [Audio Engine] Started")

        // 6. 直接播放文件
        playerNode.scheduleFile(audioFile, at: nil) {
            print("✅ [Azure TTS] Playback completed")
            DispatchQueue.main.async { [weak self] in
                self?.cleanupPlayback()
            }
        }
        playerNode.play()

        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        print("▶️ [Azure TTS] Playing audio (\(audioData.count) bytes, \(audioFile.length) frames, duration: \(String(format: "%.2f", duration))s, volume boost: +\(volumeBoostDB) dB)")
    }

    /// 清理播放資源
    private func cleanupPlayback() {
        print("🧹 [Azure TTS] Cleaning up playback resources")

        if let node = playerNode, node.isPlaying {
            node.stop()
            print("   ⏹️ Stopped player node")
        }

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            print("   ⏹️ Stopped audio engine")
        }

        // 刪除臨時文件
        if let audioFile = audioFile {
            try? FileManager.default.removeItem(at: audioFile.url)
            print("   🗑️ Removed temp file")
        }

        playerNode = nil
        eqNode = nil
        audioEngine = nil
        audioFile = nil

        print("✅ [Azure TTS] Cleanup completed")
    }

    /// 停止播放
    func stop() {
        print("⏹️ [Azure TTS] Stop requested")
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
