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

    /// ⭐️ 自動重連機制
    /// ElevenLabs STT 會在閒置時自動斷線，需要自動重連
    private var shouldAutoReconnect: Bool = false  // 是否應該自動重連（用戶主動斷開時為 false）
    private var reconnectAttempts: Int = 0  // 重連嘗試次數
    private let maxReconnectAttempts: Int = 3  // 最大重連次數
    private let reconnectDelay: TimeInterval = 1.0  // 重連延遲（秒）

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

    /// ⭐️ 防止 ElevenLabs 修正行為導致重複句子
    /// ElevenLabs 有時會在識別過程中「重寫」之前的 interim（修正識別結果）
    /// 當自動 Final 後，新的 interim 如果與上一句高度相似，應該視為「修正」而非「新句」
    private var lastFinalText: String = ""  // 上一句 Final 的文本
    private var lastFinalTime: Date = Date.distantPast  // 上一句 Final 的時間
    private let correctionTimeWindow: TimeInterval = 0.8  // 修正時間窗口：只有 0.8 秒內才可能是修正

    /// ⭐️ 智能分句：基於字符位置追蹤（避免 LLM 分段不一致問題）
    private var confirmedTextLength: Int = 0  // 已確認（發送為 final）的字符長度
    private var lastConfirmedText: String = ""  // 上次確認的完整文本（用於比對）

    /// ⭐️ 延遲確認機制：避免過早切分（如 "I can speak" + "English"）
    /// 策略：在 interim 階段只顯示翻譯，不固定句子
    ///       只有 ElevenLabs VAD commit 時才真正確認句子
    private var pendingConfirmOffset: Int = 0  // 待確認的 offset（等待 VAD commit）
    private var pendingSegments: [(original: String, translation: String)] = []  // 待確認的分句結果
    private var pendingSourceText: String = ""  // ⭐️ pendingSegments 對應的原文（用於 VAD commit 時驗證）

    // MARK: - ⭐️ 分句累積機制（核心改進）
    // 目的：避免重複翻譯已完成的分句，實現增量翻譯
    // 流程：
    //   1. 每次 smart-translate 返回後，將 isComplete=true 的分句加入 confirmedSegments
    //   2. 下次調用 smart-translate 時，只翻譯新增的部分
    //   3. VAD Commit 時，優先使用 confirmedSegments，只翻譯增量部分

    /// ⭐️ 已確認的分句累積器（isComplete=true 的分句）
    /// 這些分句不會再次發送給 LLM 翻譯
    private var confirmedSegments: [(original: String, translation: String)] = []

    /// ⭐️ 已確認分句的原文長度總和（用於快速判斷是否有新內容）
    private var confirmedOriginalLength: Int = 0

    /// ⭐️ 當前未完成的分句（isComplete=false 的最後一個分句）
    private var pendingIncompleteSegment: (original: String, translation: String)?

    /// ⭐️ 防止 race condition：VAD commit 後忽略舊的 async 翻譯回調
    /// 當 VAD commit 時設為 true，收到新 partial 時設為 false
    private var isCommitted: Bool = false

    /// Token 獲取 URL（從後端服務器獲取）
    private var tokenEndpoint: String = ""

    /// 當前語言設定
    private var currentSourceLang: Language = .zh
    private var currentTargetLang: Language = .en

    /// ⭐️ 翻譯模型提供商（可由用戶選擇）
    var translationProvider: TranslationProvider = .grok

    // Combine Publishers
    private let transcriptSubject = PassthroughSubject<TranscriptMessage, Never>()
    private let translationSubject = PassthroughSubject<(String, String), Never>()
    /// ⭐️ 分句翻譯 Publisher：(原文, 分句陣列)
    private let segmentedTranslationSubject = PassthroughSubject<(String, [TranslationSegment]), Never>()
    /// ⭐️ 修正上一句 Final 的 Publisher：(舊文本, 新文本)
    /// 當 ElevenLabs 修正之前的識別結果時，用這個 Publisher 通知 ViewModel 替換上一句
    private let correctionSubject = PassthroughSubject<(String, String), Never>()
    private let errorSubject = PassthroughSubject<String, Never>()

    var transcriptPublisher: AnyPublisher<TranscriptMessage, Never> {
        transcriptSubject.eraseToAnyPublisher()
    }

    var translationPublisher: AnyPublisher<(String, String), Never> {
        translationSubject.eraseToAnyPublisher()
    }

    /// ⭐️ 分句翻譯 Publisher
    var segmentedTranslationPublisher: AnyPublisher<(String, [TranslationSegment]), Never> {
        segmentedTranslationSubject.eraseToAnyPublisher()
    }

    /// ⭐️ 修正上一句 Publisher：(舊文本, 新文本)
    var correctionPublisher: AnyPublisher<(String, String), Never> {
        correctionSubject.eraseToAnyPublisher()
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

    // MARK: - Token 快取機制

    /// ⭐️ 快取的 token（避免每次連接都重新獲取）
    private var cachedToken: String?
    /// ⭐️ Token 過期時間（ElevenLabs single-use token 有效期約 5 分鐘，我們保守用 3 分鐘）
    private var tokenExpireTime: Date?
    /// Token 有效期（秒）
    private let tokenValidDuration: TimeInterval = 180  // 3 分鐘
    /// ⭐️ 是否正在預取 token（防止重複預取）
    private var isPrefetchingToken: Bool = false

    /// 檢查 token 是否有效
    private var isTokenValid: Bool {
        guard let token = cachedToken, let expireTime = tokenExpireTime else {
            return false
        }
        return !token.isEmpty && Date() < expireTime
    }

    // MARK: - VAD 設定（可調整）

    /// ⭐️ VAD 閾值（0.0 ~ 1.0）
    /// 越高越嚴格，需要更大聲音才會觸發語音識別
    /// 0.3 = 較敏感（預設），0.5 = 中等，0.7 = 嚴格
    var vadThreshold: Float = 0.3

    /// ⭐️ 最小語音長度（毫秒）
    /// 語音必須持續超過此時間才會被識別
    /// 100 = 較敏感（預設），300 = 中等，500 = 嚴格
    var minSpeechDurationMs: Int = 100

    /// ⭐️ 靜音閾值（秒）
    /// 靜音超過此時間後自動 commit
    var vadSilenceThresholdSecs: Float = 1.0

    // MARK: - Public Methods

    /// ⭐️ 預先獲取 token（可在 App 啟動或進入前台時調用）
    /// 這樣用戶點擊錄音時可以跳過 token 獲取步驟
    /// 完全不阻塞主線程
    func prefetchToken(serverURL: String) {
        // ⭐️ 防止重複預取（同步檢查，快速返回）
        guard !isPrefetchingToken else {
            return  // 靜默跳過，不打印日誌避免刷屏
        }

        // 如果 token 還有效，不需要預取
        guard !isTokenValid else {
            return  // 靜默跳過
        }

        // ⭐️ 標記正在預取
        isPrefetchingToken = true

        // 設定 token 端點（同步操作，很快）
        var tokenURL = serverURL
        if !tokenURL.hasPrefix("http://") && !tokenURL.hasPrefix("https://") {
            if tokenURL.contains("localhost") || tokenURL.contains("127.0.0.1") {
                tokenURL = "http://\(tokenURL)"
            } else {
                tokenURL = "https://\(tokenURL)"
            }
        }
        let endpoint = "\(tokenURL)/elevenlabs-token"

        // ⭐️ 使用 Task.detached 確保完全在背景線程執行，不阻塞 UI
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }

            // 在背景線程設置 endpoint
            await MainActor.run {
                self.tokenEndpoint = endpoint
            }

            do {
                print("🔄 [ElevenLabs] 背景預取 token...")
                let startTime = Date()
                let token = try await self.fetchToken()
                let elapsed = Date().timeIntervalSince(startTime)

                // ⭐️ 在主線程更新快取和標記
                await MainActor.run {
                    self.cachedToken = token
                    self.tokenExpireTime = Date().addingTimeInterval(self.tokenValidDuration)
                    self.isPrefetchingToken = false
                }
                print("✅ [ElevenLabs] Token 預取完成（耗時 \(String(format: "%.2f", elapsed))秒）")
            } catch {
                // ⭐️ 失敗時也要重置標記
                await MainActor.run {
                    self.isPrefetchingToken = false
                }
                print("⚠️ [ElevenLabs] Token 預取失敗: \(error.localizedDescription)")
            }
        }
    }

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

        // ⭐️ 啟用自動重連（用戶主動 connect 時）
        shouldAutoReconnect = true
        reconnectAttempts = 0

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
        // ⭐️ 禁用自動重連（用戶主動斷開）
        shouldAutoReconnect = false
        reconnectAttempts = 0

        stopPingTimer()
        stopTranslationTimer()  // ⭐️ 停止定時翻譯

        if sendCount > 0 || sendFailCount > 0 {
            print("📊 [ElevenLabs] 總計發送: \(sendCount) 次，丟棄: \(sendFailCount) 次")
        }
        sendCount = 0
        sendFailCount = 0

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

        // ⭐️ 清除 token 快取（single-use token 只能用一次，斷線後必須重新獲取）
        cachedToken = nil
        tokenExpireTime = nil
    }

    /// 發送結束語句信號（PTT 放開時調用）
    func sendEndUtterance() {
        sendCommit()
    }

    /// 發送錯誤計數（避免刷屏）
    private var sendErrorCount = 0
    private let maxSendErrorLogs = 3

    /// ⭐️ 發送失敗計數（用於日誌節流）
    private var sendFailCount = 0
    private let maxSendFailLogs = 5

    /// 發送音頻數據
    func sendAudio(data: Data) {
        guard connectionState == .connected else {
            sendFailCount += 1
            // ⭐️ 只打印前幾次和每 100 次的警告，避免刷屏
            if sendFailCount <= maxSendFailLogs || sendFailCount % 100 == 0 {
                print("⚠️ [ElevenLabs] 未連接 (state=\(connectionState))，丟棄音頻 #\(sendFailCount)")
            }
            return
        }

        // 檢查 WebSocket 是否有效
        guard let task = webSocketTask, task.state == .running else {
            sendFailCount += 1
            if sendFailCount <= maxSendFailLogs || sendFailCount % 100 == 0 {
                let taskState = webSocketTask?.state.rawValue ?? -1
                print("⚠️ [ElevenLabs] WebSocket 無效 (taskState=\(taskState))，丟棄音頻 #\(sendFailCount)")
            }
            // 更新連接狀態
            connectionState = .disconnected
            return
        }

        // ⭐️ 重置失敗計數（連接恢復）
        if sendFailCount > 0 {
            print("✅ [ElevenLabs] 連接恢復，之前丟棄了 \(sendFailCount) 個音頻")
            sendFailCount = 0
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

        // 🔍 調試：顯示發送的數據量
        if sendCount == 1 || sendCount % 20 == 0 {
            print("📤 [ElevenLabs] 發送音頻 #\(sendCount): \(data.count) bytes (\(data.count / 2) samples)")
        }

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
            let token: String

            // ⭐️ 優先使用快取的 token
            if isTokenValid, let cached = cachedToken {
                print("⚡️ [ElevenLabs] 使用快取 token（剩餘 \(Int(tokenExpireTime!.timeIntervalSinceNow))秒）")
                token = cached
            } else {
                // 需要獲取新 token
                let startTime = Date()
                token = try await fetchToken()
                let elapsed = Date().timeIntervalSince(startTime)
                print("🔑 [ElevenLabs] Token 獲取完成（耗時 \(String(format: "%.2f", elapsed))秒）")

                // 快取 token
                cachedToken = token
                tokenExpireTime = Date().addingTimeInterval(tokenValidDuration)
            }

            await connectWithToken(token, sourceLang: sourceLang)
        } catch {
            // ⭐️ Token 失敗時清除快取
            cachedToken = nil
            tokenExpireTime = nil

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
            // ⭐️ 省略 language_code 以啟用自動語言檢測
            // ElevenLabs 會自動檢測說話者的語言，支援雙向翻譯場景
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "commit_strategy", value: "vad"),  // ⭐️ 使用 VAD 自動 commit
            // ⭐️ 使用可調整的 VAD 參數
            URLQueryItem(name: "vad_silence_threshold_secs", value: String(vadSilenceThresholdSecs)),
            URLQueryItem(name: "vad_threshold", value: String(vadThreshold)),
            URLQueryItem(name: "min_speech_duration_ms", value: String(minSpeechDurationMs)),
            URLQueryItem(name: "min_silence_duration_ms", value: "500")  // 最小靜音 500ms
            // ⚠️ 注意：inactivity_timeout 是 TTS 參數，STT 不支持！
        ]

        print("🎚️ [ElevenLabs] VAD 設定: threshold=\(vadThreshold), minSpeech=\(minSpeechDurationMs)ms, silence=\(vadSilenceThresholdSecs)s")

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
    /// ElevenLabs Scribe 使用 ISO 639-1/639-3 語言代碼
    private func mapLanguageCode(_ lang: Language) -> String {
        switch lang {
        case .isLang: return "is"  // 冰島文（is 是 Swift 保留字）
        default: return lang.rawValue  // 其他語言直接使用 rawValue
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

    /// ⭐️ 檢測並清理重複模式
    /// ElevenLabs Scribe v2 有時會在 partial 階段重複輸出相同的詞彙
    /// 例如：「舍利子舍利子舍利子舍利子」應該被清理為「舍利子」
    /// - Parameter text: 原始文本
    /// - Returns: 清理後的文本
    private func cleanRepeatedPatterns(_ text: String) -> String {
        // ⭐️ 安全檢查：文本太短不需要清理
        guard text.count >= 6 else { return text }

        let originalText = text
        let maxPatternLength = min(10, text.count / 3)

        // ⭐️ 安全檢查：確保範圍有效
        guard maxPatternLength >= 2 else { return text }

        // 嘗試檢測不同長度的重複模式（2-10 個字符）
        for patternLength in 2...maxPatternLength {
            let cleaned = removeRepeatingPattern(text, patternLength: patternLength)
            if cleaned.count < text.count * 2 / 3 {
                // 如果清理掉了超過 1/3 的內容，說明有明顯重複
                print("🔄 [重複清理] 發現重複模式（長度 \(patternLength)）")
                print("   原文: \"\(originalText.prefix(50))...\"")
                print("   清理: \"\(cleaned.prefix(50))...\"")
                return cleaned
            }
        }

        return text
    }

    /// 移除指定長度的重複模式
    private func removeRepeatingPattern(_ text: String, patternLength: Int) -> String {
        guard text.count >= patternLength * 2 else { return text }

        let chars = Array(text)
        var result: [Character] = []
        var i = 0

        while i < chars.count {
            // 取當前位置開始的 patternLength 個字符作為潛在模式
            let endIndex = min(i + patternLength, chars.count)
            let potentialPattern = String(chars[i..<endIndex])

            // 計算這個模式連續出現的次數
            var repeatCount = 1
            var checkIndex = i + patternLength

            while checkIndex + patternLength <= chars.count {
                let nextChunk = String(chars[checkIndex..<(checkIndex + patternLength)])
                if nextChunk == potentialPattern {
                    repeatCount += 1
                    checkIndex += patternLength
                } else {
                    break
                }
            }

            // 如果重複超過 2 次，只保留一次
            if repeatCount > 2 {
                result.append(contentsOf: potentialPattern)
                i = checkIndex  // 跳過所有重複
            } else {
                result.append(chars[i])
                i += 1
            }
        }

        return String(result)
    }

    /// ⭐️ 檢查翻譯是否為錯誤佔位符
    /// 用於過濾 [請稀候]、[翻譯失敗] 等佔位符
    private func isErrorPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 檢查是否為 [xxx] 格式的佔位符
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return true
        }
        return false
    }

    /// ⭐️ 從 pendingSegments 獲取有效翻譯（過濾佔位符）
    private func getValidTranslationFromPending() -> String? {
        let validTranslations = pendingSegments
            .map { $0.translation }
            .filter { !isErrorPlaceholder($0) }

        guard !validTranslations.isEmpty else { return nil }
        return validTranslations.joined(separator: " ")
    }

    /// ⭐️ 檢測 ElevenLabs 修正行為
    /// ElevenLabs 有時會在識別過程中「重寫」整個 interim（不是追加，而是修正）
    /// 例如：
    ///   - 上一句 Final: "你在這邊幹嘛？ 對，我在測試它"
    ///   - 新的 interim: "你在這邊有在聽我的嗎？ 對，我在測試它"  ← 這是對上一句的修正
    ///
    /// ⭐️ 嚴格判斷標準（避免誤判正常新句子）：
    /// 1. 必須在 Final 後 0.8 秒內（超過這個時間窗口不可能是修正）
    /// 2. 新 interim 必須「包含」上一句 Final 的大部分內容（>= 60%）
    /// 3. 新 interim 的開頭必須與上一句非常相似（前 6 個字相同）
    ///
    /// - Returns: (isCorrectionBehavior: Bool, commonPart: String?)
    private func detectCorrectionBehavior(_ newInterimText: String) -> (isCorrectionBehavior: Bool, commonPart: String?) {
        guard !lastFinalText.isEmpty else { return (false, nil) }

        // ⭐️ 時間窗口檢查：只有在 Final 後很短時間內才可能是修正
        let timeSinceFinal = Date().timeIntervalSince(lastFinalTime)
        guard timeSinceFinal < correctionTimeWindow else {
            // 超過時間窗口，不可能是修正，是正常的新句子
            return (false, nil)
        }

        // ⭐️ 策略：檢查新 interim 是否「包含」上一句 Final 的大部分內容
        // 真正的修正行為特徵：
        // - 上一句: "你在這邊幹嘛？ 對，我在測試它"
        // - 新 interim: "你在這邊有在聽我的嗎？ 對，我在測試它，我在想辦法"
        // - 新 interim 包含上一句的「對，我在測試它」部分

        // 檢查共同前綴長度
        var commonPrefixLength = 0
        let lastFinalChars = Array(lastFinalText)
        let newInterimChars = Array(newInterimText)

        for i in 0..<min(lastFinalChars.count, newInterimChars.count) {
            if lastFinalChars[i] == newInterimChars[i] {
                commonPrefixLength += 1
            } else {
                break
            }
        }

        // ⭐️ 必須滿足以下所有條件才視為修正行為：
        // 1. 共同前綴 >= 6 個字（嚴格）
        // 2. 新 interim 不是上一句的簡單延續（不是純粹追加）
        // 3. 新 interim 包含上一句的後半部分（真正的重寫）

        if commonPrefixLength >= 6 {
            let commonPrefix = String(lastFinalText.prefix(commonPrefixLength))
            let lastFinalRest = String(lastFinalText.dropFirst(commonPrefixLength))
            let newInterimRest = String(newInterimText.dropFirst(commonPrefixLength))

            // 如果新 interim 的剩餘部分包含上一句的剩餘部分，說明是重寫
            // 例如：lastFinalRest = "幹嘛？ 對，我在測試它"
            //       newInterimRest = "有在聽我的嗎？ 對，我在測試它，我在想辦法"
            //       newInterimRest 包含 "對，我在測試它"

            // 找出上一句後半部分在新 interim 中的位置
            if !lastFinalRest.isEmpty && lastFinalRest.count >= 5 {
                // 取上一句後半部分的核心內容（去掉開頭幾個字）
                let coreOfLastFinal = String(lastFinalRest.dropFirst(min(3, lastFinalRest.count / 2)))
                if coreOfLastFinal.count >= 4 && newInterimRest.contains(coreOfLastFinal) {
                    print("🔄 [修正檢測] 發現修正行為（時間窗口內 \(String(format: "%.2f", timeSinceFinal))s）")
                    print("   共同前綴: \"\(commonPrefix)\"")
                    print("   上一句核心: \"\(coreOfLastFinal.prefix(20))...\"")
                    return (true, commonPrefix)
                }
            }
        }

        return (false, nil)
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

        // ⭐️ 記錄這次 Final 的文本和時間（用於檢測 ElevenLabs 修正行為）
        lastFinalText = transcriptText
        lastFinalTime = Date()

        // ⭐️ 使用 pendingSegments 的翻譯（如果有且匹配，且不是佔位符）
        // ⭐️ 修復：需要正規化後比較，避免因為空格或省略號導致不匹配
        let normalizedTranscript = transcriptText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
        let normalizedPending = pendingSourceText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")

        if !pendingSegments.isEmpty && normalizedPending == normalizedTranscript,
           let validTranslation = getValidTranslationFromPending() {
            translationSubject.send((transcriptText, validTranslation))
            print("   🌐 使用已有翻譯: \(validTranslation.prefix(40))...")
        } else {
            // 沒有現成翻譯或翻譯是佔位符，使用可靠的翻譯方法
            print("   🌐 需要重新翻譯...")
            Task {
                await self.translateAndSendFinal(transcriptText)
            }
        }

        // 重置狀態
        resetInterimState()
    }

    /// ⭐️ 重置 interim 相關狀態（包括分句累積器）
    private func resetInterimState() {
        currentInterimText = ""
        lastInterimLength = 0
        confirmedTextLength = 0
        lastConfirmedText = ""
        pendingConfirmOffset = 0
        pendingSegments = []
        pendingSourceText = ""
        lastInterimGrowthTime = Date()  // 重置計時

        // ⭐️ 重置分句累積器
        let previousConfirmedCount = confirmedSegments.count
        confirmedSegments = []
        confirmedOriginalLength = 0
        pendingIncompleteSegment = nil

        if previousConfirmedCount > 0 {
            print("🔄 [重置] 清除 \(previousConfirmedCount) 個已確認分句")
        }
    }

    /// ⭐️ 調用智能翻譯 + 分句 API
    /// Cerebras 會自動判斷輸入語言並翻譯到另一種語言
    /// 不需要客戶端判斷語言，完全由 LLM 處理
    /// ⭐️ 分句一致性：傳遞 previousSegments 讓 LLM 保持前文分句邊界
    /// ⭐️ 失敗重試：最多重試 2 次，每次間隔 300ms
    private func callSmartTranslateAPI(text: String, includePreviousSegments: Bool = true) async {
        let smartTranslateURL = tokenEndpoint.replacingOccurrences(of: "/elevenlabs-token", with: "/smart-translate")

        guard let url = URL(string: smartTranslateURL) else { return }

        // ⭐️ 簡化：直接傳遞語言對，讓 LLM 自己判斷輸入是哪種語言
        // LLM 會自動翻譯到另一種語言
        let prevCount = includePreviousSegments ? confirmedSegments.count : 0
        print("🌐 [Smart-Translate] 語言對: \(currentSourceLang.rawValue) ↔ \(currentTargetLang.rawValue), 前文分句: \(prevCount) 段")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ⭐️ 構建前文分句陣列（讓 LLM 保持分句一致性）
        var previousSegmentsArray: [[String: Any]] = []
        if includePreviousSegments && !confirmedSegments.isEmpty {
            previousSegmentsArray = confirmedSegments.map { segment in
                ["original": segment.original, "translation": segment.translation]
            }
        }

        // ⭐️ 傳遞兩個語言 + 前文分句 + 翻譯模型，讓 LLM 保持分句一致性
        let body: [String: Any] = [
            "text": text,
            "sourceLang": currentSourceLang.rawValue,
            "targetLang": currentTargetLang.rawValue,
            "mode": "streaming",
            "previousSegments": previousSegmentsArray,
            "provider": translationProvider.rawValue  // ⭐️ 傳遞用戶選擇的翻譯模型
        ]

        // ⭐️ 重試機制：最多重試 2 次
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, _) = try await URLSession.shared.data(for: request)

                // 解析智能翻譯結果（使用類別級別的 SmartTranslateResponse）
                let response = try JSONDecoder().decode(SmartTranslateResponse.self, from: data)

                // ⭐️ 檢查翻譯結果是否有效（不是空的或佔位符）
                let hasValidTranslation = response.segments.contains { segment in
                    guard let translation = segment.translation else { return false }
                    return !translation.isEmpty && !(translation.hasPrefix("[") && translation.hasSuffix("]"))
                }

                guard hasValidTranslation else {
                    throw TranslationError.emptyResult
                }

                // ⭐️ 記錄 LLM token 用量（用於計費，根據 provider 使用對應價格）
                if let usage = response.usage {
                    BillingService.shared.recordLLMUsage(
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        provider: translationProvider
                    )
                }

                await MainActor.run {
                    processSmartTranslateResponse(response, originalText: text)
                }

                // 成功，直接返回
                return

            } catch {
                lastError = error
                print("⚠️ [智能翻譯] 第 \(attempt + 1) 次失敗: \(error.localizedDescription)")

                // 如果不是最後一次嘗試，等待 300ms 再重試
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                }
            }
        }

        // ⭐️ 所有重試都失敗，使用備用方案
        print("❌ [智能翻譯] \(maxRetries) 次重試都失敗，使用備用翻譯")
        await translateTextDirectly(text, isInterim: true)
    }

    /// ⭐️ 處理智能翻譯響應（核心改進：增量分句累積）
    /// 新策略：
    /// 1. 將 isComplete=true 的分句加入 confirmedSegments（不重複）
    /// 2. 保留最後一個 isComplete=false 的分句作為 pending
    /// 3. Interim 顯示時合併 confirmed + pending
    /// 4. VAD Commit 時優先使用 confirmedSegments
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

        // ⭐️ 顯示 LLM 檢測的語言方向和增量標識
        let langInfo = response.detectedLang.map { "\($0) → \(response.translatedTo ?? "?")" } ?? "?"
        let incrementalInfo = (response.isIncremental == true) ? " [增量: 前文\(response.previousSegmentsCount ?? 0)段]" : ""
        print("✂️ [智能翻譯] \(response.segments.count) 段 (\(langInfo))\(incrementalInfo)")

        // ⭐️ 過濾掉錯誤佔位符（[請稍候]、[翻譯失敗] 等）
        let validSegments = response.segments.filter { segment in
            guard let translation = segment.translation else { return false }
            return !(translation.hasPrefix("[") && translation.hasSuffix("]"))
        }

        guard !validSegments.isEmpty else {
            print("⚠️ [智能翻譯] 所有分句都是佔位符，跳過")
            return
        }

        // ⭐️ 核心改進：增量分句累積
        // 將新的 isComplete=true 分句加入 confirmedSegments（避免重複）
        var newConfirmedCount = 0
        for segment in validSegments where segment.isComplete {
            guard let translation = segment.translation else { continue }

            // 檢查是否已經在 confirmedSegments 中（避免重複）
            let alreadyConfirmed = confirmedSegments.contains { confirmed in
                confirmed.original == segment.original
            }

            if !alreadyConfirmed {
                confirmedSegments.append((original: segment.original, translation: translation))
                confirmedOriginalLength += segment.original.count
                newConfirmedCount += 1
                print("   ✅ [累積] 新確認: \"\(segment.original.prefix(20))...\" → \"\(translation.prefix(25))...\"")
            }
        }

        // ⭐️ 保存最後一個未完成的分句
        if let lastSegment = validSegments.last, !lastSegment.isComplete, let translation = lastSegment.translation {
            pendingIncompleteSegment = (original: lastSegment.original, translation: translation)
            print("   ⏳ [待定] \"\(lastSegment.original.prefix(20))...\" → \"\(translation.prefix(25))...\"")
        } else {
            pendingIncompleteSegment = nil
        }

        // ⭐️ 同時保存完整的 pendingSegments（用於 VAD commit 時的精確匹配）
        pendingSegments = validSegments.compactMap { segment in
            if let translation = segment.translation {
                return (original: segment.original, translation: translation)
            }
            return nil
        }
        pendingConfirmOffset = response.lastCompleteOffset ?? 0
        pendingSourceText = originalText

        // ⭐️ 構建顯示用的翻譯（合併 confirmed + pending）
        var displayTranslations: [String] = []

        // 1. 已確認的分句翻譯
        for confirmed in confirmedSegments {
            displayTranslations.append(confirmed.translation)
        }

        // 2. 未完成的分句翻譯（如果有且不在 confirmed 中）
        if let pending = pendingIncompleteSegment {
            let alreadyIncluded = confirmedSegments.contains { $0.original == pending.original }
            if !alreadyIncluded {
                displayTranslations.append(pending.translation)
            }
        }

        let combinedTranslation = displayTranslations.joined(separator: " ")

        // ⭐️ 構建完整的分句列表（confirmedSegments + 當前 pending）
        // 這樣 UI 才能看到完整的一對一配對
        var allSegments: [TranslationSegment] = []

        // 1. 已確認的分句
        for confirmed in confirmedSegments {
            allSegments.append(TranslationSegment(
                original: confirmed.original,
                translation: confirmed.translation,
                isComplete: true
            ))
        }

        // 2. 當前未完成的分句（如果有且不在 confirmed 中）
        if let pending = pendingIncompleteSegment {
            let alreadyIncluded = confirmedSegments.contains { $0.original == pending.original }
            if !alreadyIncluded {
                allSegments.append(TranslationSegment(
                    original: pending.original,
                    translation: pending.translation,
                    isComplete: false
                ))
            }
        }

        // ⭐️ 發送分句翻譯結果（只要有多個累積分句就發送）
        if allSegments.count > 1 {
            // 多句：發送完整的累積分句結果
            segmentedTranslationSubject.send((originalText, allSegments))
            print("✂️ [分句翻譯] \(allSegments.count) 段 (一對一配對):")
            for (i, seg) in allSegments.enumerated() {
                let status = seg.isComplete ? "✅" : "⏳"
                print("   \(status) [\(i)] 「\(seg.original.prefix(20))」→「\(seg.translation.prefix(25))」")
            }
        } else if !combinedTranslation.isEmpty {
            // 單句：使用傳統翻譯 Publisher
            translationSubject.send((originalText, combinedTranslation))
            print("🌐 [翻譯] \(originalText.prefix(30))... → \(combinedTranslation.prefix(40))...")
        }

        // ⭐️ 統計信息
        if newConfirmedCount > 0 {
            print("📊 [分句累積] 本次新增 \(newConfirmedCount) 個確認分句，總計 \(confirmedSegments.count) 個 (\(confirmedOriginalLength) 字)")
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
        let lastCompleteOffset: Int?  // ⭐️ API 可能不返回此欄位
        let latencyMs: Int?
        // ⭐️ 新增欄位：LLM 檢測到的語言和翻譯目標
        let detectedLang: String?
        let translatedTo: String?
        let originalText: String?
        let error: String?
        // ⭐️ 新增欄位：token 使用量（用於計費）
        let usage: TokenUsage?
        // ⭐️ 新增欄位：增量處理標識（客戶端需要合併 previousSegments）
        let isIncremental: Bool?
        let previousSegmentsCount: Int?
        let processedText: String?

        struct Segment: Decodable {
            let original: String
            let translation: String?
            let isComplete: Bool
        }

        struct TokenUsage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            let totalTokens: Int
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

    /// ⭐️ 增量翻譯並發送（只翻譯新增部分，合併已確認翻譯）
    /// 用於 VAD Commit 時，已有部分翻譯但有增量的情況
    /// - Parameters:
    ///   - fullText: 完整的 Final 文本
    ///   - confirmedTranslation: 已確認分句的翻譯
    ///   - incrementalText: 需要翻譯的增量部分
    private func translateIncrementalAndSend(fullText: String, confirmedTranslation: String, incrementalText: String) async {
        print("🔄 [增量翻譯] 只翻譯增量: \"\(incrementalText.prefix(30))...\"")

        do {
            // 只翻譯增量部分
            let incrementalTranslation = try await fetchSmartTranslation(text: incrementalText)

            if !incrementalTranslation.isEmpty && !isErrorPlaceholder(incrementalTranslation) {
                // 合併已確認翻譯 + 增量翻譯
                let combinedTranslation = confirmedTranslation + " " + incrementalTranslation

                await MainActor.run {
                    translationSubject.send((fullText, combinedTranslation))
                    print("✅ [增量翻譯] 成功合併:")
                    print("   已確認: \(confirmedTranslation.prefix(30))...")
                    print("   增量: \(incrementalTranslation.prefix(30))...")
                }
                return
            }
        } catch {
            print("⚠️ [增量翻譯] 失敗: \(error.localizedDescription)")
        }

        // 增量翻譯失敗，回退到完整翻譯
        print("⚠️ [增量翻譯] 回退到完整翻譯")
        await translateAndSendFinal(fullText)
    }

    /// ⭐️ 翻譯並發送 Final 結果（確保翻譯不會丟失）
    /// 專門用於 VAD commit 時需要重新翻譯的情況
    /// 會嘗試 smart-translate，失敗則使用 translate API，最後使用重試機制
    private func translateAndSendFinal(_ text: String) async {
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                // 嘗試使用 smart-translate API
                let translation = try await fetchSmartTranslation(text: text)

                if !translation.isEmpty && !isErrorPlaceholder(translation) {
                    await MainActor.run {
                        translationSubject.send((text, translation))
                        print("✅ [翻譯成功] \(text.prefix(30))... → \(translation.prefix(40))...")
                    }
                    return
                } else {
                    // 翻譯為空或是佔位符，嘗試備用 API
                    throw TranslationError.emptyResult
                }

            } catch {
                lastError = error
                print("⚠️ [翻譯重試] 第 \(attempt + 1) 次失敗: \(error.localizedDescription)")

                // 如果不是最後一次嘗試，等待一下再重試
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                }
            }
        }

        // 所有重試都失敗，嘗試使用簡單翻譯 API
        print("⚠️ [翻譯] smart-translate 失敗，嘗試 translate API")
        await translateTextDirectly(text, isInterim: false)
    }

    /// 翻譯錯誤類型
    private enum TranslationError: Error {
        case emptyResult
        case networkError
    }

    /// 獲取 smart-translate 翻譯結果（純函數，不發送 Publisher）
    private func fetchSmartTranslation(text: String) async throws -> String {
        let smartTranslateURL = tokenEndpoint.replacingOccurrences(of: "/elevenlabs-token", with: "/smart-translate")

        guard let url = URL(string: smartTranslateURL) else {
            throw TranslationError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0  // 5 秒超時

        let body: [String: Any] = [
            "text": text,
            "sourceLang": currentSourceLang.rawValue,
            "targetLang": currentTargetLang.rawValue,
            "mode": "streaming",
            "provider": translationProvider.rawValue  // ⭐️ 傳遞用戶選擇的翻譯模型
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)

        let response = try JSONDecoder().decode(SmartTranslateResponse.self, from: data)

        // 合併所有有效的翻譯
        let translations = response.segments
            .compactMap { $0.translation }
            .filter { !isErrorPlaceholder($0) }

        guard !translations.isEmpty else {
            throw TranslationError.emptyResult
        }

        return translations.joined(separator: " ")
    }

    private func sendPing() {
        guard connectionState == .connected else { return }

        webSocketTask?.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                print("❌ [ElevenLabs] Ping 失敗: \(error.localizedDescription)")
                Task { @MainActor in
                    // ⭐️ 關鍵：如果正在自動重連，不發送錯誤給 ViewModel（避免 UI 閃爍）
                    if self.shouldAutoReconnect && self.reconnectAttempts <= self.maxReconnectAttempts {
                        print("🔄 [ElevenLabs] 自動重連中，忽略 Ping 錯誤（不通知 ViewModel）")
                        return
                    }
                    self.connectionState = .error("連接已斷開")
                    self.errorSubject.send("連接已斷開")
                }
            } else {
                print("💓 [ElevenLabs] Ping 成功")
            }
        }
    }

    // MARK: - 訊息處理

    private func receiveMessage() {
        // ⭐️ 安全檢查：確保連接仍然有效
        guard let task = webSocketTask,
              task.state == .running else {
            print("⚠️ [ElevenLabs] WebSocket 任務已結束，停止接收 (state: \(webSocketTask?.state.rawValue ?? -1))")
            return
        }

        print("👂 [ElevenLabs] 開始等待服務器消息...")

        task.receive { [weak self] result in
            guard let self = self else {
                print("⚠️ [ElevenLabs] self 已釋放")
                return
            }

            print("📬 [ElevenLabs] 收到服務器回調")

            // ⭐️ 再次檢查連接狀態
            guard self.connectionState == .connected else {
                print("⚠️ [ElevenLabs] 連接已斷開，停止接收 (state: \(self.connectionState))")
                return
            }

            switch result {
            case .success(let message):
                print("✅ [ElevenLabs] 收到消息成功")
                self.handleMessage(message)
                // ⭐️ 只在連接仍然有效時繼續接收
                if self.connectionState == .connected {
                    self.receiveMessage()
                }

            case .failure(let error):
                // ⭐️ 檢查是否為正常關閉
                let errorMessage = error.localizedDescription
                if errorMessage.contains("canceled") || errorMessage.contains("Socket is not connected") {
                    print("📱 [ElevenLabs] 連接已關閉")
                } else {
                    print("❌ [ElevenLabs] 接收錯誤: \(errorMessage)")
                }

                Task { @MainActor in
                    // 清除 token 快取
                    self.cachedToken = nil
                    self.tokenExpireTime = nil

                    // ⭐️ 關鍵：如果正在自動重連，不發送錯誤給 ViewModel（避免 UI 閃爍）
                    if self.shouldAutoReconnect && self.reconnectAttempts <= self.maxReconnectAttempts {
                        print("🔄 [ElevenLabs] 自動重連中，忽略接收錯誤（不通知 ViewModel）")
                        return
                    }

                    // ⭐️ 只在未主動斷開且非重連時設置錯誤狀態
                    if self.connectionState != .disconnected {
                        self.connectionState = .error(errorMessage)
                        self.errorSubject.send(errorMessage)
                    }
                }
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
        // ⭐️ 調試：顯示原始響應（前100字符）
        let preview = String(text.prefix(100))
        print("🔍 [ElevenLabs] 原始響應: \(preview)...")

        guard let data = text.data(using: .utf8) else {
            print("❌ [ElevenLabs] 無法轉換為 UTF8 data")
            return
        }

        do {
            let response = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)

            // 🔍 調試：顯示所有收到的消息類型
            if response.messageType != "pong" {
                print("📨 [ElevenLabs] 收到消息: \(response.messageType), text: \(response.text?.prefix(30) ?? "nil")")
            }

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

                // ⭐️ 清理重複模式（ElevenLabs 有時會重複輸出同一個詞）
                let cleanedText = cleanRepeatedPatterns(rawText)

                // ⭐️ 簡體轉繁體（如果是中文）
                let (transcriptText, wasConverted) = processChineseText(cleanedText, language: response.detectedLanguage)

                // ⭐️ 防止重複：如果新 partial 內容與剛才的 final 相同或高度相似，忽略它
                // 這解決了 ElevenLabs 持續發送相同 partial 導致重複產生 final 的問題
                if !lastFinalText.isEmpty {
                    let timeSinceFinal = Date().timeIntervalSince(lastFinalTime)
                    // 在 final 後 2 秒內，檢查是否為重複內容
                    if timeSinceFinal < 2.0 {
                        // 精確匹配
                        if transcriptText == lastFinalText {
                            print("⚠️ [partial] 跳過重複內容（與 final 相同）: \"\(transcriptText.prefix(30))...\"")
                            return
                        }
                        // 高度相似（一個是另一個的前綴，且長度差異 < 5）
                        let lengthDiff = abs(transcriptText.count - lastFinalText.count)
                        if lengthDiff < 5 {
                            if transcriptText.hasPrefix(lastFinalText) || lastFinalText.hasPrefix(transcriptText) {
                                print("⚠️ [partial] 跳過高度相似內容: \"\(transcriptText.prefix(30))...\"")
                                return
                            }
                        }
                    }
                }

                // ⭐️ 檢測 ElevenLabs 修正行為
                // 如果新的 interim 與上一句 Final 高度相似，說明 ElevenLabs 在修正之前的識別結果
                let (isCorrectionBehavior, _) = detectCorrectionBehavior(transcriptText)

                if isCorrectionBehavior && !lastFinalText.isEmpty {
                    // ⭐️ 發送修正事件：讓 ViewModel 替換上一句 Final
                    print("🔄 [partial] 檢測到修正行為，通知 ViewModel 替換上一句")
                    print("   舊: \"\(lastFinalText.prefix(30))...\"")
                    print("   新: \"\(transcriptText.prefix(30))...\"")
                    correctionSubject.send((lastFinalText, transcriptText))
                    // 清除 lastFinalText，避免重複修正
                    lastFinalText = ""
                }

                // ⭐️ 收到新的 partial，解除 commit 狀態
                // 這樣新的翻譯回調才會被處理
                isCommitted = false

                if wasConverted {
                    print("⋯ [partial] \(rawText.prefix(20))... → \(transcriptText.prefix(20))...")
                } else {
                    print("⋯ [partial] \(transcriptText.prefix(30))...")
                }

                // 更新 currentInterimText（用於定時翻譯和自動提升）
                currentInterimText = transcriptText

                // ⭐️ 立即發送 interim 轉錄（不等翻譯）
                // 讓轉錄盡快顯示在 UI 上，翻譯稍後異步更新
                let detectedLanguage = response.detectedLanguage ?? detectLanguageFromText(transcriptText)
                let transcript = TranscriptMessage(
                    text: transcriptText,
                    isFinal: false,
                    confidence: 0.7,
                    language: detectedLanguage,
                    converted: wasConverted,
                    originalText: wasConverted ? rawText : nil
                )
                transcriptSubject.send(transcript)

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

                // ⭐️ 清理重複模式（ElevenLabs 有時會重複輸出同一個詞）
                let cleanedText = cleanRepeatedPatterns(rawText)

                // ⭐️ 簡體轉繁體（如果是中文）
                let (transcriptText, wasConverted) = processChineseText(cleanedText, language: response.detectedLanguage)

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

                // ⭐️⭐️⭐️ 核心改進：每個分句 = 獨立對話框 ⭐️⭐️⭐️
                // 不再發送一個包含完整文本的 transcript
                // 而是為每個 confirmedSegments 分句發送獨立的 final transcript（帶翻譯）

                print("📊 [VAD Commit] 分句累積狀態:")
                print("   已確認分句: \(confirmedSegments.count) 個 (\(confirmedOriginalLength) 字)")

                if !confirmedSegments.isEmpty {
                    // ⭐️ 為每個已確認分句發送獨立的 final 對話框
                    print("🎯 [VAD Commit] 發送 \(confirmedSegments.count) 個獨立對話框:")
                    for (index, segment) in confirmedSegments.enumerated() {
                        var segmentTranscript = TranscriptMessage(
                            text: segment.original,
                            isFinal: true,
                            confidence: response.confidence ?? 0.9,
                            language: detectedLanguage,
                            converted: wasConverted,
                            originalText: nil
                        )
                        segmentTranscript.translation = segment.translation
                        transcriptSubject.send(segmentTranscript)
                        print("   [\(index + 1)] 「\(segment.original.prefix(20))」→「\(segment.translation.prefix(25))」")
                    }
                }

                // ⭐️ 處理 pending segment（最後一個未完成的分句）
                if let pending = pendingIncompleteSegment {
                    // 檢查是否已在 confirmedSegments 中
                    let alreadySent = confirmedSegments.contains { $0.original == pending.original }
                    if !alreadySent {
                        // ⭐️ 修復：如果 transcriptText 比 pending.original 更長，使用 transcriptText
                        // 這處理了智能翻譯回調延遲導致的「最後幾個字丟失」問題
                        let actualText: String
                        let actualTranslation: String?

                        if pending.original != transcriptText {
                            // transcriptText 與 pending 不同（可能更長或完全不同）
                            // 使用 ElevenLabs 實際確認的文本
                            actualText = transcriptText
                            actualTranslation = nil  // 需要重新翻譯
                            print("⚠️ [VAD Commit] 發現差異:")
                            print("   pending: \"\(pending.original)\"")
                            print("   actual:  \"\(transcriptText)\"")
                        } else {
                            // 完全匹配，使用 pending 的翻譯
                            actualText = pending.original
                            actualTranslation = pending.translation
                        }

                        var pendingTranscript = TranscriptMessage(
                            text: actualText,
                            isFinal: true,
                            confidence: response.confidence ?? 0.9,
                            language: detectedLanguage,
                            converted: wasConverted,
                            originalText: nil
                        )

                        if let translation = actualTranslation {
                            pendingTranscript.translation = translation
                            print("   [+] 「\(actualText.prefix(20))」→「\(translation.prefix(25))」(pending)")
                        } else {
                            print("   [+] 「\(actualText.prefix(25))」(需重新翻譯)")
                        }

                        transcriptSubject.send(pendingTranscript)

                        // 如果沒有翻譯，觸發翻譯
                        if actualTranslation == nil {
                            Task {
                                await self.translateAndSendFinal(actualText)
                            }
                        }
                    }
                }

                // ⭐️ 檢查是否有增量未被覆蓋（confirmedSegments 有內容但沒有 pending）
                if !confirmedSegments.isEmpty && pendingIncompleteSegment == nil {
                    // 計算已發送的原文總長度
                    let sentLength = confirmedSegments.reduce(0) { $0 + $1.original.count }
                    if sentLength < transcriptText.count {
                        // 有增量未被覆蓋，發送完整的 transcriptText 並重新翻譯
                        let incrementalText = String(transcriptText.dropFirst(sentLength))
                        print("⚠️ [VAD Commit] 發現未覆蓋增量:")
                        print("   已發送: \(sentLength) 字")
                        print("   實際: \(transcriptText.count) 字")
                        print("   增量: \"\(incrementalText)\"")

                        // 發送完整的 transcript（會在 ViewModel 中合併）
                        var fullTranscript = TranscriptMessage(
                            text: transcriptText,
                            isFinal: true,
                            confidence: response.confidence ?? 0.9,
                            language: detectedLanguage,
                            converted: wasConverted,
                            originalText: nil
                        )
                        transcriptSubject.send(fullTranscript)

                        // 觸發翻譯
                        Task {
                            await self.translateAndSendFinal(transcriptText)
                        }
                    }
                }

                // ⭐️ 如果沒有任何分句（極少數情況），發送完整的 transcript
                if confirmedSegments.isEmpty && pendingIncompleteSegment == nil {
                    let transcript = TranscriptMessage(
                        text: transcriptText,
                        isFinal: true,
                        confidence: response.confidence ?? 0.9,
                        language: detectedLanguage,
                        converted: wasConverted,
                        originalText: wasConverted ? rawText : nil
                    )
                    transcriptSubject.send(transcript)
                    print("⚠️ [VAD Commit] 無分句，發送完整 transcript")

                    // 觸發翻譯
                    Task {
                        await self.translateAndSendFinal(transcriptText)
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
    /// ⭐️ 失敗重試：最多重試 2 次，每次間隔 300ms
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

        // ⭐️ 重試機制：最多重試 2 次
        let maxRetries = 2

        for attempt in 0..<maxRetries {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, _) = try await URLSession.shared.data(for: request)

                struct TranslateResponse: Decodable {
                    let translatedText: String
                }

                let response = try JSONDecoder().decode(TranslateResponse.self, from: data)
                let translatedText = response.translatedText

                // ⭐️ 檢查翻譯結果是否有效
                guard !translatedText.isEmpty,
                      !(translatedText.hasPrefix("[") && translatedText.hasSuffix("]")) else {
                    throw TranslationError.emptyResult
                }

                await MainActor.run {
                    // 發送翻譯結果
                    translationSubject.send((text, translatedText))
                    print("🌐 [翻譯] \(translatedText)")
                }

                // 成功，直接返回
                return

            } catch {
                print("⚠️ [翻譯] 第 \(attempt + 1) 次失敗: \(error.localizedDescription)")

                // 如果不是最後一次嘗試，等待 300ms 再重試
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                }
            }
        }

        print("❌ [翻譯] \(maxRetries) 次重試都失敗")
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
            self.reconnectAttempts = 0  // ⭐️ 連接成功，重置重連計數
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

            // ⭐️ 清除 token 快取（single-use token 只能用一次）
            self.cachedToken = nil
            self.tokenExpireTime = nil

            // ⭐️ 自動重連邏輯
            if self.shouldAutoReconnect && self.reconnectAttempts < self.maxReconnectAttempts {
                self.reconnectAttempts += 1
                print("🔄 [ElevenLabs] 連接斷開，嘗試自動重連 (\(self.reconnectAttempts)/\(self.maxReconnectAttempts))...")

                // ⭐️ 關鍵：設為 connecting 而不是 disconnected，UI 保持原狀態
                self.connectionState = .connecting

                // 延遲後重連
                try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))

                // 確認仍然需要重連
                if self.shouldAutoReconnect && self.connectionState == .connecting {
                    print("🔗 [ElevenLabs] 執行自動重連...")
                    // 重新獲取 token 並連接
                    await self.fetchTokenAndConnect(sourceLang: self.currentSourceLang ?? .zh)
                }
            } else if self.shouldAutoReconnect && self.reconnectAttempts >= self.maxReconnectAttempts {
                print("❌ [ElevenLabs] 已達最大重連次數 (\(self.maxReconnectAttempts))，停止重連")
                self.shouldAutoReconnect = false
                self.connectionState = .disconnected  // ⭐️ 重連失敗才設為 disconnected
                self.errorSubject.send("連接失敗，請重新開始")
            } else {
                // 用戶主動斷開，不重連
                print("📱 [ElevenLabs] 用戶主動斷開，不自動重連")
                self.connectionState = .disconnected  // ⭐️ 用戶主動斷開才設為 disconnected
            }
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

                // ⭐️ 清除 token 快取（連接失敗後 token 可能已失效）
                self.cachedToken = nil
                self.tokenExpireTime = nil

                // ⭐️ 關鍵：如果正在自動重連，不發送錯誤給 ViewModel（避免 UI 閃爍）
                if self.shouldAutoReconnect && self.reconnectAttempts <= self.maxReconnectAttempts {
                    print("🔄 [ElevenLabs] 自動重連中，忽略臨時錯誤（不通知 ViewModel）")
                    // 不設置 connectionState，讓 didCloseWith 處理重連邏輯
                    return
                }

                // 只有在非重連情況下才發送錯誤
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
