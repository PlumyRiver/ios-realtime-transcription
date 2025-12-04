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

    /// ⭐️ 智能分句：由 Cerebras LLM 判斷語義完整性
    private var completedTextLength: Int = 0  // 已確認完成的文本長度（不會再改變）

    /// ⭐️ 已確認完成的句子（不會再更新）
    private var confirmedSegments: [String] = []  // 已確認的原文句子
    private var confirmedTranslations: [String] = []  // 對應的翻譯

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
        currentInterimText = ""
        lastInterimLength = 0
        lastTranslatedText = ""
        completedTextLength = 0  // 重置分句狀態
        confirmedSegments = []
        confirmedTranslations = []

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
    private func checkAndTranslateInterim() {
        let currentLength = currentInterimText.count

        // 條件 1: 檢查是否有新增（長度變長）
        guard currentLength > lastInterimLength else {
            return  // 沒有變長，不翻譯
        }

        // 條件 2: 文本不為空且與上次翻譯不同
        guard !currentInterimText.isEmpty, currentInterimText != lastTranslatedText else {
            return
        }

        let previousLength = lastInterimLength

        // 更新長度記錄
        lastInterimLength = currentLength
        lastTranslatedText = currentInterimText

        print("📝 [智能翻譯] 長度變長 \(previousLength) → \(currentLength)，調用 smart-translate")

        // ⭐️ 調用智能翻譯 API（含分句判斷）
        Task {
            await callSmartTranslateAPI(text: currentInterimText)
        }
    }

    /// ⭐️ 調用智能翻譯 + 分句 API
    /// Cerebras 會同時翻譯並判斷哪些句子「語義完整」
    private func callSmartTranslateAPI(text: String) async {
        let smartTranslateURL = tokenEndpoint.replacingOccurrences(of: "/elevenlabs-token", with: "/smart-translate")

        guard let url = URL(string: smartTranslateURL) else { return }

        // 判斷翻譯方向
        let chineseCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let isChineseText = chineseCount > text.count / 3
        let targetLang: String
        if isChineseText {
            targetLang = (currentTargetLang.rawValue == "zh") ? currentSourceLang.rawValue : currentTargetLang.rawValue
        } else {
            targetLang = (currentSourceLang.rawValue == "zh") ? currentSourceLang.rawValue : currentTargetLang.rawValue
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "targetLang": targetLang,
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
    /// 將已完成的句子固定為 final，未完成的保持 interim
    private func processSmartTranslateResponse(_ response: SmartTranslateResponse, originalText: String) {
        guard !response.segments.isEmpty else { return }

        print("✂️ [智能分句] 收到 \(response.segments.count) 個段落，lastCompleteIndex=\(response.lastCompleteIndex)")

        for (index, segment) in response.segments.enumerated() {
            let isComplete = segment.isComplete

            if isComplete {
                // ⭐️ 這個句子已經「語義完整」，固定為 final
                let alreadyConfirmed = confirmedSegments.contains(segment.original)

                if !alreadyConfirmed {
                    // 新的完整句子：發送 final transcript
                    let transcript = TranscriptMessage(
                        text: segment.original,
                        isFinal: true,
                        confidence: 0.95,
                        language: nil
                    )
                    transcriptSubject.send(transcript)
                    confirmedSegments.append(segment.original)

                    // 發送翻譯
                    if let translation = segment.translation, !translation.isEmpty {
                        translationSubject.send((segment.original, translation))
                        confirmedTranslations.append(translation)
                    }

                    print("✅ [分句固定] \(segment.original) → \(segment.translation ?? "")")
                }
            } else {
                // ⭐️ 這個句子還沒說完，顯示為 interim
                let transcript = TranscriptMessage(
                    text: segment.original,
                    isFinal: false,
                    confidence: 0.7,
                    language: nil
                )
                transcriptSubject.send(transcript)

                // 也發送 interim 翻譯（讓用戶即時看到）
                if let translation = segment.translation, !translation.isEmpty {
                    translationSubject.send((segment.original, translation))
                }

                print("⏳ [interim] \(segment.original) → \(segment.translation ?? "")")
            }
        }

        // 更新已完成的文本長度
        if response.lastCompleteOffset > 0 {
            completedTextLength = response.lastCompleteOffset
        }
    }

    /// SmartTranslateResponse 結構（用於解碼）
    private struct SmartTranslateResponse: Decodable {
        let segments: [Segment]
        let lastCompleteIndex: Int
        let lastCompleteOffset: Int
        let latencyMs: Int?

        struct Segment: Decodable {
            let original: String
            let translation: String?
            let isComplete: Bool
        }
    }

    /// 直接翻譯文本
    /// - Parameters:
    ///   - text: 要翻譯的文本
    ///   - isInterim: 是否為 interim 翻譯（用於分句判斷，預設 true）
    private func translateTextDirectly(_ text: String, isInterim: Bool = true) async {
        // 判斷翻譯方向
        let sourceLangCode = currentSourceLang.rawValue
        let targetLangCode = currentTargetLang.rawValue

        // 簡單判斷：如果是中文字符多，則是中文
        let chineseCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let isChineseText = chineseCount > text.count / 3

        let translateTo: String
        if isChineseText {
            translateTo = (targetLangCode == "zh") ? sourceLangCode : targetLangCode
        } else {
            translateTo = (sourceLangCode == "zh") ? sourceLangCode : targetLangCode
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
                guard let transcriptText = response.text, !transcriptText.isEmpty else { return }

                // ⭐️ 簡化版：只累積 interim 文本，分句由 smart-translate API 處理
                let confidence = response.confidence ?? 0
                let language = response.detectedLanguage

                // 發送 interim transcript（UI 顯示用）
                let transcript = TranscriptMessage(
                    text: transcriptText,
                    isFinal: false,
                    confidence: confidence,
                    language: language
                )
                transcriptSubject.send(transcript)
                print("⋯ [interim] \(transcriptText)")

                // ⭐️ 更新 interim 文本（用於定時智能翻譯）
                // 注意：這裡保存完整的 interim，讓 smart-translate API 來判斷分句
                currentInterimText = transcriptText

            case "committed_transcript":
                // ⭐️ 忽略此訊息，只處理 committed_transcript_with_timestamps
                // 避免重複發送相同的轉錄結果
                guard let transcriptText = response.text, !transcriptText.isEmpty else { return }
                print("📝 [ElevenLabs] committed (等待 with_timestamps): \(transcriptText.prefix(30))...")

            case "committed_transcript_with_timestamps":
                guard let transcriptText = response.text, !transcriptText.isEmpty else { return }

                // 打印時間戳
                if let words = response.words {
                    for word in words.prefix(3) {
                        print("   📍 \(word.text ?? "") @ \(word.start ?? 0)s")
                    }
                }

                // ⭐️ 計算還沒被確認的部分（智能分句可能已經處理了一些）
                // 找出還沒發送過的文本
                var unconfirmedText = transcriptText
                for confirmed in confirmedSegments {
                    if let range = unconfirmedText.range(of: confirmed) {
                        unconfirmedText.removeSubrange(range)
                    }
                }
                unconfirmedText = unconfirmedText.trimmingCharacters(in: .whitespaces)

                if !unconfirmedText.isEmpty {
                    // 發送剩餘的文本作為 final
                    let transcript = TranscriptMessage(
                        text: unconfirmedText,
                        isFinal: true,
                        confidence: response.confidence ?? 0,
                        language: response.detectedLanguage
                    )
                    transcriptSubject.send(transcript)
                    print("✅ [Final 剩餘] \(unconfirmedText)")

                    // 翻譯剩餘文本
                    Task {
                        await self.translateTextDirectly(unconfirmedText, isInterim: false)
                    }
                }

                // ⭐️ 重置所有狀態（準備下一輪）
                currentInterimText = ""
                lastInterimLength = 0
                completedTextLength = 0
                confirmedSegments = []
                confirmedTranslations = []

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
