//
//  ElevenLabsSTTService.swift
//  ios_realtime_trans
//
//  ElevenLabs Scribe v2 Realtime 語音轉文字服務
//  WebSocket API: wss://api.elevenlabs.io/v1/speech-to-text/realtime
//

import Foundation
import Combine

/// ElevenLabs STT 服務
/// 使用 Scribe v2 Realtime 模型進行即時語音轉文字
@Observable
final class ElevenLabsSTTService: NSObject, WebSocketServiceProtocol {

    // MARK: - Properties

    private(set) var connectionState: WebSocketConnectionState = .disconnected

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// 心跳計時器
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 20.0

    /// ⭐️ 定時智能翻譯計時器（用於 interim 結果）
    private var translationTimer: Timer?
    private let translationInterval: TimeInterval = 0.5  // 每 0.5 秒檢查一次
    private var currentInterimText: String = ""  // 當前累積的 interim 文本（完整）
    private var lastInterimLength: Int = 0  // 上次 interim 長度（用於檢測是否變長）
    private var lastTranslatedText: String = ""  // 上次翻譯的文本（避免重複翻譯）

    /// ⭐️ Interim 自動提升為 Final 機制
    /// 當 interim 持續一段時間沒有變長時，自動提升為 final
    private var lastInterimGrowthTime: Date = Date()  // 上次 interim 變長的時間
    private let interimStaleThreshold: TimeInterval = 1.0  // 停滯閾值：1 秒

    /// ⭐️ 智能分句：基於字符位置追蹤（避免 LLM 分段不一致問題）
    private var confirmedTextLength: Int = 0  // 已確認（發送為 final）的字符長度
    private var lastConfirmedText: String = ""  // 上次確認的完整文本（用於比對）

    /// ⭐️ 延遲確認機制：避免過早切分（如 "I can speak" + "English"）
    /// 策略：在 interim 階段只顯示翻譯，不固定句子
    ///       只有 ElevenLabs VAD commit 時才真正確認句子
    private var pendingConfirmOffset: Int = 0  // 待確認的 offset（等待 VAD commit）
    private var pendingSegments: [(original: String, translation: String)] = []  // 待確認的分句結果
    private var pendingSourceText: String = ""  // ⭐️ pendingSegments 對應的原文（用於 VAD commit 時驗證）

    /// ⭐️ 防止 race condition：VAD commit 後忽略舊的 async 翻譯回調
    /// 當 VAD commit 時設為 true，收到新 partial 時設為 false
    private var isCommitted: Bool = false

    /// Token 獲取 URL（從後端服務器獲取）
    private var tokenEndpoint: String = ""

    /// 當前語言設定
    private var currentSourceLang: Language = .zh
    private var currentTargetLang: Language = .en

    // Combine Publishers
    private let transcriptSubject = PassthroughSubject<TranscriptMessage, Never>()
    private let translationSubject = PassthroughSubject<(String, String), Never>()
    private let errorSubject = PassthroughSubject<String, Never>()

    var transcriptPublisher: AnyPublisher<TranscriptMessage, Never> {
        transcriptSubject.eraseToAnyPublisher()
    }

    var translationPublisher: AnyPublisher<(String, String), Never> {
        translationSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<String, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    /// 發送計數器
    private var sendCount = 0

    // MARK: - ElevenLabs API 設定

    /// ElevenLabs WebSocket 端點
    private let elevenLabsWSEndpoint = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"

    /// 模型 ID
    private let modelId = "scribe_v2_realtime"

    /// ⭐️ 分句閾值：超過此長度的 final 結果會自動分句
    private let segmentThreshold = 30

    // MARK: - Public Methods

    /// 連接到 ElevenLabs Scribe v2 Realtime API
    /// - Parameters:
    ///   - serverURL: 後端服務器 URL（用於獲取 token）
    ///   - sourceLang: 來源語言
    ///   - targetLang: 目標語言
    func connect(serverURL: String, sourceLang: Language, targetLang: Language) {
        // 防止重複連接
        if case .connecting = connectionState {
            print("⚠️ [ElevenLabs] 已經在連接中，忽略")
            return
        }
        if case .connected = connectionState {
            print("⚠️ [ElevenLabs] 已經連接，忽略")
            return
        }

        // 保存語言設定
        currentSourceLang = sourceLang
        currentTargetLang = targetLang

        // 清理舊連接（不改變狀態）
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        stopPingTimer()

        connectionState = .connecting

        // 設定 token 端點（使用後端服務器）
        var tokenURL = serverURL
        if !tokenURL.hasPrefix("http://") && !tokenURL.hasPrefix("https://") {
            if tokenURL.contains("localhost") || tokenURL.contains("127.0.0.1") {
                tokenURL = "http://\(tokenURL)"
            } else {
                tokenURL = "https://\(tokenURL)"
            }
        }
        tokenEndpoint = "\(tokenURL)/elevenlabs-token"

        print("🔑 [ElevenLabs] 正在獲取 token...")

        // 獲取 token 並連接
        Task {
            await fetchTokenAndConnect(sourceLang: sourceLang)
        }
    }

    /// 斷開連接
    func disconnect() {
        stopPingTimer()
        stopTranslationTimer()  // ⭐️ 停止定時翻譯

        if sendCount > 0 {
            print("📊 [ElevenLabs] 總計發送: \(sendCount) 次音頻")
        }
        sendCount = 0

        // 重置翻譯狀態
        resetInterimState()
        lastTranslatedText = ""
        isCommitted = false  // 重置 commit 狀態

        // 發送結束信號
        sendCommit()

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
    }

    /// 發送結束語句信號（PTT 放開時調用）
    func sendEndUtterance() {
        sendCommit()
    }

    /// 發送錯誤計數（避免刷屏）
    private var sendErrorCount = 0
    private let maxSendErrorLogs = 3

    /// 發送音頻數據
    func sendAudio(data: Data) {
        guard connectionState == .connected else {
            if sendCount == 0 {
                print("⚠️ [ElevenLabs] 未連接，無法發送音頻")
            }
            return
        }

        // 檢查 WebSocket 是否有效
        guard let task = webSocketTask, task.state == .running else {
            if sendErrorCount < maxSendErrorLogs {
                print("⚠️ [ElevenLabs] WebSocket 已關閉，停止發送")
                sendErrorCount += 1
            }
            // 更新連接狀態
            connectionState = .disconnected
            return
        }

        let base64String = data.base64EncodedString()

        // ElevenLabs 音頻訊息格式
        let audioMessage: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64String,
            "commit": false,
            "sample_rate": 16000
        ]

        sendCount += 1

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: audioMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                task.send(message) { [weak self] error in
                    if let error {
                        guard let self else { return }
                        // 只打印前幾次錯誤，避免刷屏
                        if self.sendErrorCount < self.maxSendErrorLogs {
                            print("❌ [ElevenLabs] 發送音頻錯誤: \(error.localizedDescription)")
                            self.sendErrorCount += 1
                        }
                        // 如果是連接取消錯誤，更新狀態
                        if error.localizedDescription.contains("canceled") || error.localizedDescription.contains("timed out") {
                            Task { @MainActor in
                                self.connectionState = .disconnected
                            }
                        }
                    }
                }
            }
        } catch {
            print("❌ [ElevenLabs] 編碼音頻訊息錯誤: \(error)")
        }
    }

    // MARK: - Private Methods

    /// 獲取 token 並連接
    private func fetchTokenAndConnect(sourceLang: Language) async {
        do {
            let token = try await fetchToken()
            await connectWithToken(token, sourceLang: sourceLang)
        } catch {
            await MainActor.run {
                print("❌ [ElevenLabs] 獲取 token 失敗: \(error.localizedDescription)")
                connectionState = .error("獲取 token 失敗")
                errorSubject.send("獲取 token 失敗: \(error.localizedDescription)")
            }
        }
    }

    /// 從後端服務器獲取 ElevenLabs token
    private func fetchToken() async throws -> String {
        guard let url = URL(string: tokenEndpoint) else {
            throw ElevenLabsError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ElevenLabsError.tokenFetchFailed
        }

        struct TokenResponse: Decodable {
            let token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.token
    }

    /// 使用 token 連接 WebSocket
    @MainActor
    private func connectWithToken(_ token: String, sourceLang: Language) {
        // 建立 WebSocket URL
        var urlComponents = URLComponents(string: elevenLabsWSEndpoint)!
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: modelId),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "language_code", value: mapLanguageCode(sourceLang)),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "commit_strategy", value: "vad"),  // ⭐️ 使用 VAD 自動 commit
            URLQueryItem(name: "vad_silence_threshold_secs", value: "1.0"),  // 1 秒靜音後 commit
            URLQueryItem(name: "vad_threshold", value: "0.3"),  // VAD 靈敏度
            URLQueryItem(name: "min_speech_duration_ms", value: "100"),
            URLQueryItem(name: "min_silence_duration_ms", value: "500")  // 最小靜音 500ms
        ]

        guard let url = urlComponents.url else {
            connectionState = .error("無效的 WebSocket URL")
            errorSubject.send("無效的 WebSocket URL")
            return
        }

        print("🔗 [ElevenLabs] 連接到 WebSocket: \(url)")

        // 建立 URLSession
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        // 建立 WebSocket Task
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // 開始接收訊息
        receiveMessage()
    }

    /// 語言代碼映射
    private func mapLanguageCode(_ lang: Language) -> String {
        switch lang {
        case .auto: return "auto"
        case .zh: return "zh"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .es: return "es"
        case .fr: return "fr"
        case .de: return "de"
        case .it: return "it"
        case .pt: return "pt"
        case .ru: return "ru"
        case .ar: return "ar"
        case .hi: return "hi"
        case .th: return "th"
        case .vi: return "vi"
        }
    }

    /// ⭐️ 根據文本內容自動檢測語言
    /// 用於 ElevenLabs 沒有回傳 detected_language 時
    private func detectLanguageFromText(_ text: String) -> String {
        // 統計各種字符的數量
        var chineseCount = 0
        var japaneseCount = 0
        var koreanCount = 0
        var latinCount = 0
        var arabicCount = 0
        var thaiCount = 0
        var devanagariCount = 0  // Hindi

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0x4E00 && value <= 0x9FFF {
                // CJK 統一漢字
                chineseCount += 1
            } else if value >= 0x3040 && value <= 0x309F {
                // 平假名
                japaneseCount += 1
            } else if value >= 0x30A0 && value <= 0x30FF {
                // 片假名
                japaneseCount += 1
            } else if value >= 0xAC00 && value <= 0xD7AF {
                // 韓文音節
                koreanCount += 1
            } else if value >= 0x0041 && value <= 0x007A {
                // 拉丁字母 (A-Z, a-z)
                latinCount += 1
            } else if value >= 0x0600 && value <= 0x06FF {
                // 阿拉伯文
                arabicCount += 1
            } else if value >= 0x0E00 && value <= 0x0E7F {
                // 泰文
                thaiCount += 1
            } else if value >= 0x0900 && value <= 0x097F {
                // 天城文（Hindi）
                devanagariCount += 1
            }
        }

        // 找出數量最多的語言
        let counts: [(String, Int)] = [
            ("zh", chineseCount),
            ("ja", japaneseCount),
            ("ko", koreanCount),
            ("en", latinCount),
            ("ar", arabicCount),
            ("th", thaiCount),
            ("hi", devanagariCount)
        ]

        // 如果有日文假名，優先判斷為日文（即使有漢字）
        if japaneseCount > 0 {
            return "ja"
        }

        // 如果有韓文，判斷為韓文
        if koreanCount > 0 {
            return "ko"
        }

        // 取最大值
        if let maxCount = counts.max(by: { $0.1 < $1.1 }), maxCount.1 > 0 {
            return maxCount.0
        }

        // 默認返回來源語言
        return currentSourceLang.rawValue
    }

    /// ⭐️ 簡體中文轉繁體中文
    /// 使用 iOS 內建的 ICU StringTransform
    /// - Parameter text: 原始文本（可能包含簡體字）
    /// - Returns: 轉換後的繁體文本
    private func convertToTraditionalChinese(_ text: String) -> String {
        // 使用 CFStringTransform 進行簡繁轉換
        let mutableString = NSMutableString(string: text)

        // "Simplified-Traditional" 是 ICU transform ID
        // 將簡體中文轉換為繁體中文
        CFStringTransform(mutableString, nil, "Simplified-Traditional" as CFString, false)

        return mutableString as String
    }

    /// ⭐️ 檢測文本是否包含簡體中文字符
    /// 通過比較轉換前後是否相同來判斷
    private func containsSimplifiedChinese(_ text: String) -> Bool {
        let traditional = convertToTraditionalChinese(text)
        return traditional != text
    }

    /// ⭐️ 處理中文文本：如果是簡體則轉換為繁體
    /// - Parameters:
    ///   - text: 原始文本
    ///   - language: 檢測到的語言代碼
    /// - Returns: (處理後的文本, 是否進行了轉換)
    private func processChineseText(_ text: String, language: String?) -> (text: String, converted: Bool) {
        // 只對中文進行處理
        let lang = language ?? ""
        let isChinese = lang.hasPrefix("zh") || lang == "cmn" || detectLanguageFromText(text) == "zh"

        guard isChinese else {
            return (text, false)
        }

        // 檢查是否需要轉換
        let traditionalText = convertToTraditionalChinese(text)
        let wasConverted = traditionalText != text

        if wasConverted {
            print("🔄 [簡→繁] \(text) → \(traditionalText)")
        }

        return (traditionalText, wasConverted)
    }

    /// ⭐️ 檢查文本是否為純標點符號或空白
    /// 用於過濾無意義的 transcript（如單獨的句號、問號）
    private func isPunctuationOnly(_ text: String) -> Bool {
        let meaningfulChars = text.filter { !$0.isPunctuation && !$0.isWhitespace }
        return meaningfulChars.isEmpty
    }

    /// 發送 commit 信號（結束當前語句）
    private func sendCommit() {
        guard connectionState == .connected else { return }

        let commitMessage: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
            "sample_rate": 16000
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: commitMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { error in
                    if let error {
                        print("❌ [ElevenLabs] 發送 commit 錯誤: \(error.localizedDescription)")
                    } else {
                        print("🔚 [ElevenLabs] 已發送 commit 信號")
                    }
                }
            }
        } catch {
            print("❌ [ElevenLabs] 編碼 commit 訊息錯誤: \(error)")
        }
    }

    // MARK: - 心跳機制

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        print("💓 [ElevenLabs] 心跳計時器已啟動（每 \(Int(pingInterval)) 秒）")
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: - 定時翻譯機制

    /// 啟動定時翻譯計時器
    private func startTranslationTimer() {
        stopTranslationTimer()
        translationTimer = Timer.scheduledTimer(withTimeInterval: translationInterval, repeats: true) { [weak self] _ in
            self?.checkAndTranslateInterim()
        }
        print("🌐 [ElevenLabs] 定時翻譯計時器已啟動（每 \(translationInterval) 秒）")
    }

    /// 停止定時翻譯計時器
    private func stopTranslationTimer() {
        translationTimer?.invalidate()
        translationTimer = nil
    }

    /// 檢查並調用智能翻譯（含分句判斷）
    /// ⭐️ 新增：Interim 停滯超過 1 秒自動提升為 Final
    private func checkAndTranslateInterim() {
        let currentLength = currentInterimText.count
        let now = Date()

        // ⭐️ 情況 1: 長度變長 → 翻譯並重置計時
        if currentLength > lastInterimLength {
            // 更新長度記錄
            let previousLength = lastInterimLength
            lastInterimLength = currentLength
            lastInterimGrowthTime = now  // ⭐️ 重置停滯計時

            // 條件檢查：文本不為空且與上次翻譯不同
            guard !currentInterimText.isEmpty, currentInterimText != lastTranslatedText else {
                return
            }

            lastTranslatedText = currentInterimText

            print("📝 [智能翻譯] 長度變長 \(previousLength) → \(currentLength)，調用 smart-translate")

            // 調用智能翻譯 API
            Task {
                await callSmartTranslateAPI(text: currentInterimText)
            }
            return
        }

        // ⭐️ 情況 2: 長度沒變，檢查是否停滯超過閾值
        // 條件：有內容、未 commit、停滯超過 1 秒
        guard !currentInterimText.isEmpty,
              !isCommitted,
              currentLength > 0 else {
            return
        }

        let staleDuration = now.timeIntervalSince(lastInterimGrowthTime)
        if staleDuration >= interimStaleThreshold {
            // ⭐️ 停滯超過 1 秒，自動提升為 final
            print("⏰ [自動 Final] interim 停滯 \(String(format: "%.1f", staleDuration)) 秒，自動提升為 final")
            promoteInterimToFinal()
        }
    }

    /// ⭐️ 將當前 interim 提升為 final（用於停滯超時）
    private func promoteInterimToFinal() {
        guard !currentInterimText.isEmpty, !isCommitted else { return }

        let transcriptText = currentInterimText

        // 標記為已提升（防止重複）
        isCommitted = true

        // ⭐️ 過濾純標點符號
        guard !isPunctuationOnly(transcriptText) else {
            print("⚠️ [自動 Final] 跳過純標點: \"\(transcriptText)\"")
            resetInterimState()
            return
        }

        // ⭐️ 語言檢測
        let detectedLanguage = detectLanguageFromText(transcriptText)

        // 發送 final transcript
        let transcript = TranscriptMessage(
            text: transcriptText,
            isFinal: true,
            confidence: 0.85,  // 自動提升的信心度稍低
            language: detectedLanguage
        )
        transcriptSubject.send(transcript)
        print("✅ [自動 Final] \(transcriptText.prefix(40))...")

        // ⭐️ 使用 pendingSegments 的翻譯（如果有且匹配）
        if !pendingSegments.isEmpty && pendingSourceText == transcriptText {
            let combinedTranslation = pendingSegments.map { $0.translation }.joined(separator: " ")
            translationSubject.send((transcriptText, combinedTranslation))
            print("   🌐 使用已有翻譯: \(combinedTranslation.prefix(40))...")
        } else {
            // 沒有現成翻譯，異步請求
            Task {
                await self.translateTextDirectly(transcriptText, isInterim: false)
            }
        }

        // 重置狀態
        resetInterimState()
    }

    /// ⭐️ 重置 interim 相關狀態
    private func resetInterimState() {
        currentInterimText = ""
        lastInterimLength = 0
        confirmedTextLength = 0
        lastConfirmedText = ""
        pendingConfirmOffset = 0
        pendingSegments = []
        pendingSourceText = ""
        lastInterimGrowthTime = Date()  // 重置計時
    }

    /// ⭐️ 調用智能翻譯 + 分句 API
    /// Cerebras 會自動判斷輸入語言並翻譯到另一種語言
    /// 不需要客戶端判斷語言，完全由 LLM 處理
    private func callSmartTranslateAPI(text: String) async {
        let smartTranslateURL = tokenEndpoint.replacingOccurrences(of: "/elevenlabs-token", with: "/smart-translate")

        guard let url = URL(string: smartTranslateURL) else { return }

        // ⭐️ 簡化：直接傳遞語言對，讓 LLM 自己判斷輸入是哪種語言
        // LLM 會自動翻譯到另一種語言
        print("🌐 [Smart-Translate] 語言對: \(currentSourceLang.rawValue) ↔ \(currentTargetLang.rawValue)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ⭐️ 傳遞兩個語言，讓 LLM 自己判斷輸入是哪種並翻譯到另一種
        let body: [String: Any] = [
            "text": text,
            "sourceLang": currentSourceLang.rawValue,
            "targetLang": currentTargetLang.rawValue,
            "mode": "streaming"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)

            // 解析智能翻譯結果（使用類別級別的 SmartTranslateResponse）
            let response = try JSONDecoder().decode(SmartTranslateResponse.self, from: data)

            await MainActor.run {
                processSmartTranslateResponse(response, originalText: text)
            }

        } catch {
            print("❌ [智能翻譯] 錯誤: \(error.localizedDescription)")
            // 備用方案：使用普通翻譯
            await translateTextDirectly(text, isInterim: true)
        }
    }

    /// ⭐️ 處理智能翻譯響應
    /// 新策略：在 interim 階段「只翻譯，不確認」
    /// - 所有內容都作為 interim 發送（包括 LLM 認為 complete 的）
    /// - 只有 ElevenLabs VAD commit 時才真正確認句子
    /// - 這樣可以避免「I can speak」+「English」的切分問題
    private func processSmartTranslateResponse(_ response: SmartTranslateResponse, originalText: String) {
        guard !response.segments.isEmpty else { return }

        // ⭐️ 過濾純標點符號（避免單獨的句號、問號成為氣泡）
        guard !isPunctuationOnly(originalText) else {
            print("⚠️ [智能翻譯] 跳過純標點: \"\(originalText)\"")
            return
        }

        // ⭐️ 防止 race condition：如果已經 commit，忽略這個舊的回調
        guard !isCommitted else {
            print("⚠️ [智能翻譯] 已 commit，忽略舊回調: \(originalText.prefix(30))...")
            return
        }

        // ⭐️ 顯示 LLM 檢測的語言方向
        let langInfo = response.detectedLang.map { "\($0) → \(response.translatedTo ?? "?")" } ?? "?"
        print("✂️ [智能翻譯] \(response.segments.count) 段 (\(langInfo)) (interim 模式)")

        // ⭐️ 保存分句結果（等待 VAD commit 時使用）
        pendingSegments = response.segments.compactMap { segment in
            if let translation = segment.translation {
                return (original: segment.original, translation: translation)
            }
            return nil
        }
        pendingConfirmOffset = response.lastCompleteOffset
        pendingSourceText = originalText  // ⭐️ 記錄這個翻譯對應的原文

        // ⭐️ 在 interim 階段：整段文本作為 interim 發送
        // 不切分，保持完整性
        // ⭐️ 使用 LLM 檢測的語言（如果有），否則本地檢測
        let detectedLanguage = response.detectedLang ?? detectLanguageFromText(originalText)
        let transcript = TranscriptMessage(
            text: originalText,
            isFinal: false,
            confidence: 0.7,
            language: detectedLanguage
        )
        transcriptSubject.send(transcript)

        // ⭐️ 合併所有翻譯作為 interim 翻譯
        // 過濾掉錯誤佔位符（[請稍候]、[翻譯失敗] 等）
        let validTranslations = response.segments.compactMap { $0.translation }.filter { translation in
            !translation.hasPrefix("[") || !translation.hasSuffix("]")
        }
        let allTranslations = validTranslations.joined(separator: " ")
        if !allTranslations.isEmpty {
            translationSubject.send((originalText, allTranslations))
            print("⏳ [interim] \(originalText.prefix(30))... → \(allTranslations.prefix(40))...")
        }
    }

    /// 從 segments 中找到匹配的翻譯
    private func findTranslationForText(_ text: String, in segments: [SmartTranslateResponse.Segment]) -> String? {
        // 精確匹配
        if let segment = segments.first(where: { $0.original == text }) {
            return segment.translation
        }

        // 部分匹配（text 包含在某個 segment 中，或 segment 包含在 text 中）
        for segment in segments {
            if segment.original.contains(text) || text.contains(segment.original) {
                return segment.translation
            }
        }

        // 合併所有相關 segments 的翻譯
        var matchedTranslations: [String] = []
        var remainingText = text
        for segment in segments {
            if remainingText.hasPrefix(segment.original) {
                if let translation = segment.translation {
                    matchedTranslations.append(translation)
                }
                remainingText = String(remainingText.dropFirst(segment.original.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if !matchedTranslations.isEmpty {
            return matchedTranslations.joined(separator: " ")
        }

        return nil
    }

    /// SmartTranslateResponse 結構（用於解碼）
    private struct SmartTranslateResponse: Decodable {
        let segments: [Segment]
        let lastCompleteIndex: Int
        let lastCompleteOffset: Int
        let latencyMs: Int?
        // ⭐️ 新增欄位：LLM 檢測到的語言和翻譯目標
        let detectedLang: String?
        let translatedTo: String?
        let originalText: String?
        let error: String?

        struct Segment: Decodable {
            let original: String
            let translation: String?
            let isComplete: Bool
        }
    }

    /// 直接翻譯文本（備用方案，當 smart-translate 失敗時使用）
    /// - Parameters:
    ///   - text: 要翻譯的文本
    ///   - isInterim: 是否為 interim 翻譯（用於分句判斷，預設 true）
    private func translateTextDirectly(_ text: String, isInterim: Bool = true) async {
        // ⭐️ 使用本地語言檢測作為備用方案
        // 注意：這只用於 smart-translate 失敗時，正常情況下 LLM 會自己判斷
        let detectedLang = detectLanguageFromText(text)

        // ⭐️ 判斷翻譯方向
        let translateTo: String
        if detectedLang == currentSourceLang.rawValue {
            translateTo = currentTargetLang.rawValue
        } else if detectedLang == currentTargetLang.rawValue {
            translateTo = currentSourceLang.rawValue
        } else {
            translateTo = currentTargetLang.rawValue
        }

        await callTranslationAPI(text: text, targetLang: translateTo, isInterim: isInterim)
    }

    private func sendPing() {
        guard connectionState == .connected else { return }

        webSocketTask?.sendPing { [weak self] error in
            if let error {
                print("❌ [ElevenLabs] Ping 失敗: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.connectionState = .error("連接已斷開")
                    self?.errorSubject.send("連接已斷開")
                }
            } else {
                print("💓 [ElevenLabs] Ping 成功")
            }
        }
    }

    // MARK: - 訊息處理

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                print("❌ [ElevenLabs] 接收錯誤: \(error.localizedDescription)")
                self.connectionState = .error(error.localizedDescription)
                self.errorSubject.send(error.localizedDescription)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerResponse(text)
            }
        @unknown default:
            break
        }
    }

    /// 解析 ElevenLabs 伺服器回應
    private func parseServerResponse(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)

            switch response.messageType {
            case "session_started":
                print("✅ [ElevenLabs] Session 開始: \(response.sessionId ?? "N/A")")

            case "partial_transcript":
                guard let rawText = response.text, !rawText.isEmpty else { return }

                // ⭐️ 過濾純標點符號（避免單獨的句號、問號成為氣泡）
                guard !isPunctuationOnly(rawText) else {
                    print("⋯ [partial] 跳過純標點: \"\(rawText)\"")
                    return
                }

                // ⭐️ 收到新的 partial，解除 commit 狀態
                // 這樣新的翻譯回調才會被處理
                isCommitted = false

                // ⭐️ 簡體轉繁體（如果是中文）
                let (transcriptText, wasConverted) = processChineseText(rawText, language: response.detectedLanguage)
                if wasConverted {
                    print("⋯ [partial] \(rawText.prefix(20))... → \(transcriptText.prefix(20))...")
                } else {
                    print("⋯ [partial] \(transcriptText.prefix(30))...")
                }

                // ⭐️ 只更新 currentInterimText，不發送 interim
                // interim 由 processSmartTranslateResponse 統一發送（帶翻譯）
                // 避免重複發送導致 UI 混亂
                currentInterimText = transcriptText

            case "committed_transcript":
                // ⭐️ 忽略此訊息，只處理 committed_transcript_with_timestamps
                // 避免重複發送相同的轉錄結果
                guard let transcriptText = response.text, !transcriptText.isEmpty else { return }
                print("📝 [ElevenLabs] committed (等待 with_timestamps): \(transcriptText.prefix(30))...")

            case "committed_transcript_with_timestamps":
                guard let rawText = response.text, !rawText.isEmpty else { return }

                // ⭐️ 防止重複：如果已經被自動提升為 final，跳過 VAD commit
                // 場景：用戶停止說話 → 1秒後自動 final → VAD 也發送 commit
                // 這時 isCommitted = true，避免同一句話出現兩次
                if isCommitted {
                    print("⚠️ [VAD Commit] 已被自動提升，跳過: \"\(rawText.prefix(30))...\"")
                    return
                }

                // ⭐️ 過濾純標點符號（在簡繁轉換之前過濾，避免無意義處理）
                guard !isPunctuationOnly(rawText) else {
                    print("🔒 [VAD Commit] 跳過純標點: \"\(rawText)\"")
                    resetInterimState()
                    return
                }

                // ⭐️ 標記為已 commit，讓後續的 async 翻譯回調被忽略
                isCommitted = true

                // ⭐️ 簡體轉繁體（如果是中文）
                let (transcriptText, wasConverted) = processChineseText(rawText, language: response.detectedLanguage)

                if wasConverted {
                    print("🔒 [VAD Commit] 確認句子: \(rawText.prefix(30))... → \(transcriptText.prefix(30))...")
                } else {
                    print("🔒 [VAD Commit] 確認句子: \(transcriptText.prefix(40))...")
                }
                print("   🌐 detected_language: \(response.detectedLanguage ?? "nil")")

                // 打印時間戳
                if let words = response.words {
                    for word in words.prefix(3) {
                        print("   📍 \(word.text ?? "") @ \(word.start ?? 0)s")
                    }
                }

                // ⭐️ VAD commit 時確認句子
                // 策略：發送完整的 transcriptText 作為 final（與 interim 匹配）
                // 這樣 ViewModel 會正確清除 interimTranscript

                // ⭐️ 語言檢測：如果 ElevenLabs 沒有回傳，自己判斷
                let detectedLanguage: String
                if let lang = response.detectedLanguage, !lang.isEmpty {
                    detectedLanguage = lang
                } else {
                    // 自動檢測：根據文本內容判斷
                    detectedLanguage = detectLanguageFromText(transcriptText)
                }

                let transcript = TranscriptMessage(
                    text: transcriptText,
                    isFinal: true,
                    confidence: response.confidence ?? 0.9,
                    language: detectedLanguage,
                    converted: wasConverted,  // ⭐️ 記錄是否進行了簡繁轉換
                    originalText: wasConverted ? rawText : nil  // ⭐️ 保存原始簡體文本
                )
                transcriptSubject.send(transcript)

                // ⭐️ 使用 pendingSegments 的翻譯（如果有，且原文匹配）
                // 防止 race condition：pendingSegments 可能是上一句話的翻譯
                //
                // ⭐️ 關鍵判斷：翻譯是否完整
                // 情況 1：pendingSourceText == transcriptText（完全匹配，翻譯應該完整）
                // 情況 2：pendingSourceText 是 transcriptText 的前綴（翻譯不完整，需重新翻譯）
                // 情況 3：transcriptText 是 pendingSourceText 的前綴（異常情況）
                // 情況 4：完全不匹配（上一句的翻譯）

                let isPendingExactMatch = !pendingSegments.isEmpty && pendingSourceText == transcriptText
                let isPendingPartialMatch = !pendingSegments.isEmpty && transcriptText.hasPrefix(pendingSourceText) && pendingSourceText != transcriptText
                let isPendingReverseMatch = !pendingSegments.isEmpty && pendingSourceText.hasPrefix(transcriptText) && pendingSourceText != transcriptText

                if isPendingExactMatch {
                    // ✅ 完全匹配：直接使用 pendingSegments 的翻譯
                    let combinedTranslation = pendingSegments.map { $0.translation }.joined(separator: " ")
                    translationSubject.send((transcriptText, combinedTranslation))
                    print("✅ [確認] 完全匹配: \(transcriptText.prefix(40))... → \(combinedTranslation.prefix(40))...")
                } else if isPendingPartialMatch {
                    // ⚠️ 部分匹配：翻譯不完整（句子說完後才 commit，但最後一次翻譯是在句子中間）
                    // 需要重新翻譯完整句子
                    print("⚠️ [確認] 翻譯不完整，需重新翻譯")
                    print("   最終句子: \(transcriptText.prefix(50))...")
                    print("   已翻譯部分: \(pendingSourceText.prefix(50))...")
                    Task {
                        await self.translateTextDirectly(transcriptText, isInterim: false)
                    }
                } else if isPendingReverseMatch {
                    // ⚠️ 異常情況：VAD commit 的文本比翻譯的原文短
                    // 可能是 ElevenLabs 截斷了文本，使用現有翻譯但記錄警告
                    let combinedTranslation = pendingSegments.map { $0.translation }.joined(separator: " ")
                    translationSubject.send((transcriptText, combinedTranslation))
                    print("⚠️ [確認] 異常：commit 文本較短，使用現有翻譯")
                    print("   commit: \(transcriptText.prefix(50))...")
                    print("   翻譯原文: \(pendingSourceText.prefix(50))...")
                } else {
                    // ⚠️ pendingSegments 不匹配（可能是上一句的翻譯），重新翻譯
                    if !pendingSegments.isEmpty {
                        print("⚠️ [確認] pendingSegments 不匹配，忽略舊翻譯")
                        print("   期望: \(transcriptText.prefix(30))...")
                        print("   實際: \(pendingSourceText.prefix(30))...")
                    }
                    print("✅ [確認] \(transcriptText.prefix(40))... (需要重新翻譯)")
                    Task {
                        await self.translateTextDirectly(transcriptText, isInterim: false)
                    }
                }

                // ⭐️ 重置所有狀態（準備下一輪）
                resetInterimState()

            case "auth_error", "quota_exceeded_error", "throttled_error", "rate_limited_error":
                let errorMsg = response.message ?? "認證或配額錯誤"
                print("❌ [ElevenLabs] \(response.messageType): \(errorMsg)")
                errorSubject.send(errorMsg)
                connectionState = .error(errorMsg)

            case "error":
                let errorMsg = response.message ?? "未知錯誤"
                print("❌ [ElevenLabs] 錯誤: \(errorMsg)")
                errorSubject.send(errorMsg)

            default:
                print("⚠️ [ElevenLabs] 未知訊息類型: \(response.messageType)")
            }

        } catch {
            print("❌ [ElevenLabs] 解析回應錯誤: \(error)")
        }
    }

    // MARK: - 分句功能

    /// 調用後端分句 API，將長文本分成多個有意義的句子
    private func segmentAndSend(_ text: String, confidence: Double, language: String?) async {
        let segmentURL = tokenEndpoint.replacingOccurrences(of: "/elevenlabs-token", with: "/segment")

        guard let url = URL(string: segmentURL) else {
            // 分句失敗，發送原文
            await sendSingleTranscript(text, confidence: confidence, language: language)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "sourceLang": currentSourceLang.rawValue,
            "targetLang": currentTargetLang.rawValue
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)

            // 解析分句結果
            struct SegmentResponse: Decodable {
                let segments: [Segment]
                let latencyMs: Int?

                struct Segment: Decodable {
                    let original: String
                    let translation: String?
                }
            }

            let response = try JSONDecoder().decode(SegmentResponse.self, from: data)

            print("✂️ [分句] 分成 \(response.segments.count) 句 (\(response.latencyMs ?? 0)ms)")

            // 逐個發送分句結果
            await MainActor.run {
                for (index, segment) in response.segments.enumerated() {
                    let transcript = TranscriptMessage(
                        text: segment.original,
                        isFinal: true,
                        confidence: confidence,
                        language: language
                    )

                    // 發送轉錄
                    transcriptSubject.send(transcript)
                    print("   ✅ [\(index + 1)] \(segment.original)")

                    // 發送翻譯（如果有）
                    if let translation = segment.translation, !translation.isEmpty {
                        translationSubject.send((segment.original, translation))
                        print("   🌐 [\(index + 1)] \(translation)")
                    }
                }
            }

        } catch {
            print("❌ [分句] 錯誤: \(error.localizedDescription)")
            // 分句失敗，發送原文
            await sendSingleTranscript(text, confidence: confidence, language: language)
        }
    }

    /// 發送單一轉錄（分句失敗時的後備方案）
    private func sendSingleTranscript(_ text: String, confidence: Double, language: String?) async {
        await MainActor.run {
            let transcript = TranscriptMessage(
                text: text,
                isFinal: true,
                confidence: confidence,
                language: language
            )
            transcriptSubject.send(transcript)
            print("✅ [ElevenLabs] \(text)")
        }

        // 翻譯
        if text != lastTranslatedText {
            lastTranslatedText = text
            await translateTextDirectly(text)
        }
    }

    // MARK: - 翻譯功能（備用，當智能翻譯失敗時使用）

    /// 調用後端翻譯 API（簡單版，不含分句）
    /// - Parameters:
    ///   - text: 要翻譯的原文
    ///   - targetLang: 目標語言
    ///   - isInterim: 是否為 interim 翻譯
    private func callTranslationAPI(text: String, targetLang: String, isInterim: Bool = false) async {
        // 使用現有的後端翻譯端點
        let translateURL = tokenEndpoint.replacingOccurrences(of: "/elevenlabs-token", with: "/translate")

        guard let url = URL(string: translateURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "targetLang": targetLang,
            "sourceLang": "auto"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)

            struct TranslateResponse: Decodable {
                let translatedText: String
            }

            let response = try JSONDecoder().decode(TranslateResponse.self, from: data)
            let translatedText = response.translatedText

            await MainActor.run {
                // 發送翻譯結果
                translationSubject.send((text, translatedText))
                print("🌐 [翻譯] \(translatedText)")
            }

        } catch {
            print("❌ [ElevenLabs] 翻譯錯誤: \(error.localizedDescription)")
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension ElevenLabsSTTService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            print("✅ [ElevenLabs] WebSocket 連接成功")
            self.connectionState = .connected
            self.sendErrorCount = 0  // 重置錯誤計數
            self.startPingTimer()
            self.startTranslationTimer()  // ⭐️ 啟動定時翻譯
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            print("📱 [ElevenLabs] WebSocket 連接關閉 (code: \(closeCode.rawValue))")
            self.connectionState = .disconnected
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            if let error {
                print("❌ [ElevenLabs] URLSession 錯誤: \(error.localizedDescription)")
                self.connectionState = .error(error.localizedDescription)
                self.errorSubject.send(error.localizedDescription)
            }
        }
    }
}

// MARK: - ElevenLabs 資料模型

/// ElevenLabs API 回應
struct ElevenLabsResponse: Decodable {
    let messageType: String
    let sessionId: String?
    let text: String?
    let confidence: Double?
    let detectedLanguage: String?
    let message: String?
    let words: [ElevenLabsWord]?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case sessionId = "session_id"
        case text
        case confidence
        case detectedLanguage = "detected_language"
        case message
        case words
    }
}

/// ElevenLabs 單詞時間戳
struct ElevenLabsWord: Decodable {
    let text: String?
    let start: Double?
    let end: Double?
    let type: String?
    let speakerId: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case type
        case speakerId = "speaker_id"
    }
}

/// ElevenLabs 錯誤類型
enum ElevenLabsError: LocalizedError {
    case invalidURL
    case tokenFetchFailed
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無效的 URL"
        case .tokenFetchFailed:
            return "獲取 ElevenLabs token 失敗"
        case .connectionFailed:
            return "連接 ElevenLabs 失敗"
        }
    }
}
