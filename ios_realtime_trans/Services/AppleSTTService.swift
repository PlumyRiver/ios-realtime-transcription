//
//  AppleSTTService.swift
//  ios_realtime_trans
//
//  Apple 內建 STT 服務（雙語言並行識別）
//  使用 SFSpeechRecognizer 進行設備端語音識別
//  優點：免費、離線可用、低延遲、無 API 配額限制
//  缺點：語言支援較少、需要用戶下載語言包
//

import Foundation
import Speech
import AVFoundation
import Combine

/// Apple STT 服務（設備端雙語言並行識別）
class AppleSTTService: NSObject, WebSocketServiceProtocol {

    // MARK: - Properties

    /// 雙語言識別器
    private var sourceRecognizer: SFSpeechRecognizer?
    private var targetRecognizer: SFSpeechRecognizer?

    /// 識別任務
    private var sourceTask: SFSpeechRecognitionTask?
    private var targetTask: SFSpeechRecognitionTask?

    /// 識別請求
    private var sourceRequest: SFSpeechAudioBufferRecognitionRequest?
    private var targetRequest: SFSpeechAudioBufferRecognitionRequest?

    /// 當前語言設置
    private var sourceLang: Language = .zh
    private var targetLang: Language = .en

    /// ⭐️ 經濟模式：單語言模式
    private(set) var isSingleLanguageMode: Bool = false
    private(set) var currentActiveLanguage: Language = .zh

    // MARK: - ⭐️ 自動語言切換（經濟模式）

    /// 音頻環形緩衝區（儲存最近 5 秒的音頻）
    private let audioRingBuffer = AudioRingBuffer(capacitySeconds: 5.0, sampleRate: 16000)

    /// 是否啟用自動語言切換
    var isAutoLanguageSwitchEnabled: Bool = true

    /// 信心度閾值（低於此值觸發切換）
    var confidenceThreshold: Float = 0.70

    /// 是否正在進行語言比較
    private var isComparingLanguages: Bool = false

    /// 比較中的結果暫存
    private var comparisonResults: [Language: (text: String, confidence: Float)] = [:]

    /// 比較完成後的回調（用於 UI 更新）
    var onLanguageComparisonComplete: ((Language, String, Float) -> Void)?

    /// 語言切換回調（用於同步 UI）
    var onLanguageSwitched: ((Language) -> Void)?

    /// 低信心度閾值（低於此值的 Final 視為不可靠）
    private let unreliableFinalThreshold: Float = 0.30

    /// ⭐️ 比較顯示模式：強制兩種語言都辨識一次，並顯示兩個結果
    /// 用於調試和比較兩種語言的辨識效果
    var isComparisonDisplayMode: Bool = false

    /// 比較結果回調（顯示兩個語言的結果）- 舊版（比較顯示模式用）
    var onComparisonResults: ((_ results: [(lang: Language, text: String, confidence: Float, isFinal: Bool)]) -> Void)?

    /// ⭐️ 最佳比較結果回調（經濟模式 PTT 用）
    /// 選擇信心水準最高的語言，並觸發翻譯 + TTS
    var onBestComparisonResult: ((_ bestLang: Language, _ text: String, _ confidence: Float) -> Void)?

    /// 連接狀態
    private(set) var connectionState: WebSocketConnectionState = .disconnected

    /// 翻譯模型選擇
    var translationProvider: TranslationProvider = .grok

    /// 伺服器 URL（用於翻譯 API）
    private var serverURL: String = ""

    // MARK: - Publishers

    private let _transcriptSubject = PassthroughSubject<TranscriptMessage, Never>()
    private let _translationSubject = PassthroughSubject<(String, String), Never>()
    private let _segmentedTranslationSubject = PassthroughSubject<(String, [TranslationSegment]), Never>()
    private let _correctionSubject = PassthroughSubject<(String, String), Never>()
    private let _errorSubject = PassthroughSubject<String, Never>()

    var transcriptPublisher: AnyPublisher<TranscriptMessage, Never> {
        _transcriptSubject.eraseToAnyPublisher()
    }
    var translationPublisher: AnyPublisher<(String, String), Never> {
        _translationSubject.eraseToAnyPublisher()
    }
    var segmentedTranslationPublisher: AnyPublisher<(String, [TranslationSegment]), Never> {
        _segmentedTranslationSubject.eraseToAnyPublisher()
    }
    var correctionPublisher: AnyPublisher<(String, String), Never> {
        _correctionSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<String, Never> {
        _errorSubject.eraseToAnyPublisher()
    }

    // MARK: - 信心度追蹤

    /// 最新的來源語言識別結果
    private var lastSourceResult: RecognitionResult?
    /// 最新的目標語言識別結果
    private var lastTargetResult: RecognitionResult?

    /// 識別結果結構
    private struct RecognitionResult {
        let text: String
        let confidence: Float
        let language: String
        let isFinal: Bool
        let timestamp: Date
    }

    /// 上一次發送的結果（用於去重）
    private var lastEmittedText: String = ""
    private var lastEmittedLanguage: String = ""

    // MARK: - 防抖與超時

    /// 防抖計時器（合併短時間內的結果）
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.15  // 150ms 防抖

    /// 任務重建計時器（Apple STT 有約 1 分鐘限制）
    private var taskRebuildTimer: Timer?
    private let taskRebuildInterval: TimeInterval = 55.0  // 55 秒重建

    /// 音頻格式
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - 統計

    private var recognitionStartTime: Date?
    private var totalAudioDuration: TimeInterval = 0

    /// ⭐️ 辨識延遲統計
    private var lastAudioSendTime: Date?           // 最後一次發送音頻的時間
    private var audioSendTimestamps: [Date] = []   // 音頻發送時間記錄（最近 10 個）
    private var recognitionLatencies: [TimeInterval] = []  // 辨識延遲記錄（ms）

    // MARK: - 防止無限重啟

    /// 重建冷卻時間（防止快速循環重啟）
    private var lastRebuildTime: Date?
    private let rebuildCooldown: TimeInterval = 3.0  // 至少 3 秒才能重建

    /// 連續錯誤計數（用於決定是否放棄）
    private var consecutiveErrorCount = 0
    private let maxConsecutiveErrors = 5

    // MARK: - Initialization

    override init() {
        super.init()
        print("✅ [Apple STT] 服務初始化")
    }

    // MARK: - WebSocketServiceProtocol

    func connect(serverURL: String, sourceLang: Language, targetLang: Language) {
        self.serverURL = serverURL
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.isSingleLanguageMode = false  // 預設為雙語言模式

        connectionState = .connecting

        // 請求語音識別權限
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.handleAuthorizationStatus(status)
            }
        }
    }

    // MARK: - ⭐️ 經濟模式：單語言模式

    /// 單語言模式連接（經濟模式用）
    /// 只開啟一個語言識別器，節省資源
    func connectSingleLanguage(
        serverURL: String,
        sourceLang: Language,
        targetLang: Language,
        activeLanguage: Language
    ) {
        self.serverURL = serverURL
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.isSingleLanguageMode = true
        self.currentActiveLanguage = activeLanguage

        connectionState = .connecting

        print("🌿 [Apple STT] 經濟模式：單語言連接 (\(activeLanguage.shortName))")

        // 請求語音識別權限
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.handleAuthorizationStatus(status)
            }
        }
    }

    /// 切換語言（經濟模式專用）
    /// 返回切換耗時（毫秒）
    @discardableResult
    func switchLanguage(to language: Language) -> TimeInterval {
        guard isSingleLanguageMode else {
            print("⚠️ [Apple STT] switchLanguage 只能在單語言模式下使用")
            return 0
        }

        guard language != currentActiveLanguage else {
            print("ℹ️ [Apple STT] 已經是 \(language.shortName)，無需切換")
            return 0
        }

        let startTime = Date()
        print("🔄 [Apple STT] 開始切換語言: \(currentActiveLanguage.shortName) → \(language.shortName)")

        // 停止當前識別
        stopSingleLanguageRecognition()

        // 更新當前語言
        currentActiveLanguage = language

        // 啟動新語言識別
        startSingleLanguageRecognition()

        // 計算切換時間
        let switchTime = Date().timeIntervalSince(startTime) * 1000  // 轉換為毫秒
        print("⏱️ [Apple STT] 語言切換完成，耗時: \(String(format: "%.0f", switchTime))ms")

        return switchTime
    }

    /// 停止單語言識別
    private func stopSingleLanguageRecognition() {
        sourceTask?.cancel()
        sourceTask = nil
        sourceRequest?.endAudio()
        sourceRequest = nil
        sourceRecognizer = nil

        // ⭐️ 停止重建計時器
        singleLanguageRebuildTimer?.invalidate()
        singleLanguageRebuildTimer = nil

        // 重置結果
        lastSourceResult = nil
        lastEmittedText = ""
        lastEmittedLanguage = ""
    }

    /// ⭐️ 單語言模式任務重建計時器
    private var singleLanguageRebuildTimer: Timer?
    private let singleLanguageRebuildInterval: TimeInterval = 50.0  // 50 秒重建（Apple 限制約 1 分鐘）

    /// 啟動單語言識別
    private func startSingleLanguageRecognition() {
        let locale = Locale(identifier: currentActiveLanguage.azureLocale)
        sourceRecognizer = SFSpeechRecognizer(locale: locale)

        guard let recognizer = sourceRecognizer else {
            connectionState = .error("\(currentActiveLanguage.displayName) 識別器創建失敗")
            _errorSubject.send("不支援 \(currentActiveLanguage.displayName) 語音識別")
            return
        }

        guard recognizer.isAvailable else {
            connectionState = .error("\(currentActiveLanguage.displayName) 識別器不可用")
            _errorSubject.send("請下載 \(currentActiveLanguage.displayName) 語言包")
            return
        }

        // 創建識別請求
        sourceRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = sourceRequest else {
            connectionState = .error("無法創建識別請求")
            return
        }

        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // 啟動識別任務
        sourceTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleSingleLanguageResult(result: result, error: error)
        }

        // ⭐️ 設置任務重建計時器（避免 Apple STT 1 分鐘超時限制）
        setupSingleLanguageRebuildTimer()

        connectionState = .connected
        print("✅ [Apple STT] 單語言識別已啟動: \(currentActiveLanguage.shortName)")
    }

    /// ⭐️ 設置單語言模式的任務重建計時器
    private func setupSingleLanguageRebuildTimer() {
        singleLanguageRebuildTimer?.invalidate()
        // ⭐️ 使用 .common mode，確保 UI 操作時 timer 也能觸發
        singleLanguageRebuildTimer = Timer(timeInterval: singleLanguageRebuildInterval, repeats: true) { [weak self] _ in
            self?.rebuildSingleLanguageTask()
        }
        if let timer = singleLanguageRebuildTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        print("⏰ [Apple STT] 單語言重建計時器已啟動 (\(Int(singleLanguageRebuildInterval))秒, .common mode)")
    }

    /// ⭐️ 重建單語言識別任務（避免 1 分鐘超時）
    private func rebuildSingleLanguageTask() {
        guard isSingleLanguageMode, connectionState == .connected else { return }

        // ⭐️ 如果正在比較語言，跳過重建
        guard !isComparingLanguages else {
            print("⏸️ [Apple STT] 比較模式中，跳過重建")
            return
        }

        // ⭐️ 冷卻時間檢查（防止快速循環重啟）
        if let lastRebuild = lastRebuildTime,
           Date().timeIntervalSince(lastRebuild) < rebuildCooldown {
            print("⏳ [Apple STT] 重建冷卻中，跳過本次重建")
            return
        }

        lastRebuildTime = Date()
        print("🔄 [Apple STT] 重建單語言識別任務（避免超時）")

        // 結束舊任務
        sourceTask?.cancel()
        sourceRequest?.endAudio()
        sourceTask = nil
        sourceRequest = nil

        // 重置狀態
        lastEmittedText = ""

        // 短暫延遲後重建（讓系統釋放資源）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isSingleLanguageMode, self.connectionState == .connected else { return }

            // 重新創建識別請求和任務
            guard let recognizer = self.sourceRecognizer, recognizer.isAvailable else {
                print("⚠️ [Apple STT] 識別器不可用，無法重建")
                return
            }

            self.sourceRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = self.sourceRequest else {
                print("⚠️ [Apple STT] 無法創建識別請求")
                return
            }

            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            self.sourceTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.handleSingleLanguageResult(result: result, error: error)
            }

            print("✅ [Apple STT] 單語言識別任務已重建")
        }
    }

    /// 處理單語言識別結果
    private func handleSingleLanguageResult(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        // 複用現有的錯誤處理邏輯
        if let error = error {
            let nsError = error as NSError
            if nsError.code == 1 || nsError.code == 216 { return }

            if nsError.code == 1110 {
                consecutiveErrorCount += 1
                if consecutiveErrorCount == 1 {
                    print("ℹ️ [Apple STT/\(currentActiveLanguage.shortName)] 等待語音輸入...")
                } else if consecutiveErrorCount % 10 == 0 {
                    print("ℹ️ [Apple STT] 持續等待語音... (已等待 \(consecutiveErrorCount) 次)")
                }

                // ⭐️ 修復：單語言模式也要有重建邏輯（和雙語言模式一致）
                if consecutiveErrorCount >= maxConsecutiveErrors * 2 {
                    // 檢查冷卻時間
                    if let lastRebuild = lastRebuildTime,
                       Date().timeIntervalSince(lastRebuild) < rebuildCooldown {
                        // 還在冷卻中，不重建
                        return
                    }

                    print("🔄 [Apple STT] 長時間無語音，嘗試重建單語言任務...")
                    consecutiveErrorCount = 0
                    lastRebuildTime = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.rebuildSingleLanguageTask()
                    }
                }
                return
            }

            print("⚠️ [Apple STT/\(currentActiveLanguage.shortName)] 錯誤: \(error.localizedDescription)")
            return
        }

        consecutiveErrorCount = 0

        guard let result = result else { return }

        let text = result.bestTranscription.formattedString
        guard !text.isEmpty else { return }

        let confidence = result.bestTranscription.segments.last?.confidence ?? 0
        let isFinal = result.isFinal

        // 去重
        if text == lastEmittedText && !isFinal { return }

        // ⭐️ 計算辨識延遲
        var latencyInfo = ""
        if let lastSend = lastAudioSendTime {
            let latency = Date().timeIntervalSince(lastSend) * 1000  // ms
            recognitionLatencies.append(latency)
            if recognitionLatencies.count > 20 {
                recognitionLatencies.removeFirst()
            }
            let avgLatency = recognitionLatencies.reduce(0, +) / Double(recognitionLatencies.count)
            latencyInfo = " | 延遲: \(String(format: "%.0f", latency))ms (平均: \(String(format: "%.0f", avgLatency))ms)"
        }

        // ⭐️ Interim 結果沒有信心度（Apple 的設計），只有 Final 才顯示
        let confidenceInfo = isFinal ? " (信心: \(String(format: "%.2f", confidence)))" : ""
        let finalTag = isFinal ? "✅ Final" : "⏳ Interim"
        print("🎤 [Apple STT/\(currentActiveLanguage.shortName)] \(finalTag): \"\(text.prefix(40))\"\(confidenceInfo)\(latencyInfo)")

        // 創建 TranscriptMessage
        let transcript = TranscriptMessage(
            text: text,
            isFinal: isFinal,
            confidence: Double(confidence),
            language: currentActiveLanguage.rawValue
        )

        if isFinal {
            lastEmittedText = ""

            // ⭐️ 比較顯示模式：強制兩種語言都辨識一次
            if isSingleLanguageMode && isComparisonDisplayMode && !isComparingLanguages {
                print("🔬 [比較模式] 收到 Final，開始強制比較兩種語言")
                comparisonResults[currentActiveLanguage] = (text: text, confidence: confidence)
                startLanguageComparison()
                return
            }

            // ⭐️ 自動語言切換邏輯
            if isSingleLanguageMode && isAutoLanguageSwitchEnabled && !isComparisonDisplayMode && !isComparingLanguages {
                // 檢查信心度是否低於閾值
                // 注意：Apple STT 有時 Final 信心度為 0（bug），這種情況也要觸發切換
                let shouldSwitch = confidence < confidenceThreshold || confidence == 0
                if shouldSwitch {
                    print("⚠️ [自動切換] 信心度 \(String(format: "%.2f", confidence)) < \(String(format: "%.2f", confidenceThreshold))，嘗試另一種語言")

                    // 儲存當前結果
                    comparisonResults[currentActiveLanguage] = (text: text, confidence: confidence)

                    // 觸發語言比較
                    startLanguageComparison()
                    return  // 不發送結果，等待比較完成
                }
            }

            // 如果是比較模式，處理比較結果
            if isComparingLanguages {
                handleComparisonResult(text: text, confidence: confidence, isFinal: true)
                return
            }

            // 正常模式：觸發翻譯
            translateText(text: text, detectedLang: currentActiveLanguage.rawValue)
        } else {
            lastEmittedText = text

            // ⭐️ 比較模式下也保存 Interim 結果（作為備用）
            if isComparingLanguages {
                // 使用負數信心度標記為 Interim（Interim 沒有信心度）
                comparisonResults[currentActiveLanguage] = (text: text, confidence: -1.0)
                print("📝 [自動切換] 暫存 Interim: \(currentActiveLanguage.shortName) = \"\(text.prefix(20))...\"")
            }
        }

        DispatchQueue.main.async {
            self._transcriptSubject.send(transcript)
        }
    }

    func disconnect() {
        print("🔌 [Apple STT] 斷開連接")

        // 停止任務
        sourceTask?.cancel()
        targetTask?.cancel()
        sourceTask = nil
        targetTask = nil

        // 結束請求
        sourceRequest?.endAudio()
        targetRequest?.endAudio()
        sourceRequest = nil
        targetRequest = nil

        // 清除識別器
        sourceRecognizer = nil
        targetRecognizer = nil

        // 停止計時器
        debounceTimer?.invalidate()
        debounceTimer = nil
        taskRebuildTimer?.invalidate()
        taskRebuildTimer = nil
        singleLanguageRebuildTimer?.invalidate()  // ⭐️ 單語言模式重建計時器
        singleLanguageRebuildTimer = nil

        // 重置狀態
        lastSourceResult = nil
        lastTargetResult = nil
        lastEmittedText = ""
        lastEmittedLanguage = ""

        // 重置計數器
        audioSendCount = 0
        sourceErrorCount = 0
        targetErrorCount = 0

        // ⭐️ 重置自動切換狀態
        isComparingLanguages = false
        comparisonResults.removeAll()
        audioRingBuffer.clear()
        consecutiveErrorCount = 0
        lastRebuildTime = nil

        // ⭐️ 重置延遲統計
        lastAudioSendTime = nil
        audioSendTimestamps.removeAll()
        recognitionLatencies.removeAll()
        totalAudioDuration = 0

        connectionState = .disconnected
    }

    /// 音頻發送計數器
    private var audioSendCount = 0

    func sendAudio(data: Data) {
        // ⭐️ 第一次調用時打印詳細狀態
        if audioSendCount == 0 {
            print("🔍 [Apple STT] sendAudio 首次調用:")
            print("   connectionState: \(connectionState)")
            print("   sourceRequest: \(sourceRequest != nil ? "存在" : "nil")")
            print("   targetRequest: \(targetRequest != nil ? "存在" : "nil")")
            print("   data.count: \(data.count) bytes")
        }

        guard connectionState == .connected else {
            if audioSendCount % 50 == 0 {  // 減少 log 噪音
                print("⚠️ [Apple STT] sendAudio: 未連接 (\(connectionState))，忽略")
            }
            audioSendCount += 1
            return
        }

        audioSendCount += 1

        // ⭐️ 經濟模式：儲存音頻到環形緩衝區（用於自動語言切換重試）
        if isSingleLanguageMode && isAutoLanguageSwitchEnabled && !isComparingLanguages {
            audioRingBuffer.write(data)
        }

        // 每 20 次打印一次 debug info
        if audioSendCount == 1 || audioSendCount % 20 == 0 {
            print("📤 [Apple STT] 收到音頻 #\(audioSendCount): \(data.count) bytes")
            if isSingleLanguageMode && isAutoLanguageSwitchEnabled {
                print("   📼 緩衝區: \(String(format: "%.1f", audioRingBuffer.bufferedDuration))秒")
            }
        }

        // 轉換 PCM Int16 → AVAudioPCMBuffer
        guard let buffer = convertToAudioBuffer(data: data) else {
            print("❌ [Apple STT] 音頻轉換失敗 (data.count: \(data.count))")
            return
        }

        // ⭐️ 根據模式檢查 request
        if isSingleLanguageMode {
            // 單語言模式：只需要 sourceRequest
            guard let srcReq = sourceRequest else {
                print("❌ [Apple STT] 單語言模式：Request 為空")
                return
            }
            srcReq.append(buffer)
        } else {
            // 雙語言模式：需要兩個 request
            guard let srcReq = sourceRequest, let tgtReq = targetRequest else {
                print("❌ [Apple STT] Request 為空，無法發送音頻")
                print("   sourceRequest: \(sourceRequest != nil)")
                print("   targetRequest: \(targetRequest != nil)")
                return
            }
            srcReq.append(buffer)
            tgtReq.append(buffer)
        }

        // ⭐️ 計算音頻振幅（調試用）
        var maxAmplitude: Float = 0
        var avgAmplitude: Float = 0
        if let floatData = buffer.floatChannelData?[0] {
            let frameCount = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameCount {
                let absVal = abs(floatData[i])
                sum += absVal
                if absVal > maxAmplitude {
                    maxAmplitude = absVal
                }
            }
            avgAmplitude = sum / Float(frameCount)
        }

        // 統計音頻時長
        let duration = Double(buffer.frameLength) / 16000.0
        totalAudioDuration += duration

        // ⭐️ 記錄發送時間（用於計算辨識延遲）
        let now = Date()
        lastAudioSendTime = now
        audioSendTimestamps.append(now)
        if audioSendTimestamps.count > 10 {
            audioSendTimestamps.removeFirst()
        }

        // 每 20 次打印一次（包含振幅資訊）
        if audioSendCount == 1 || audioSendCount % 20 == 0 {
            print("   ✅ 已發送到識別器 (累計 \(String(format: "%.1f", totalAudioDuration))秒)")
            print("   📊 振幅: max=\(String(format: "%.4f", maxAmplitude)), avg=\(String(format: "%.6f", avgAmplitude))")

            // 振幅警告
            if maxAmplitude < 0.01 {
                print("   ⚠️ 音頻振幅過低！可能是靜音或麥克風問題")
            }
        }
    }

    func sendEndUtterance() {
        // Apple STT 會自動檢測語音結束
        // 但我們可以強制結束當前識別並重建任務
        print("📤 [Apple STT] 收到結束語句信號")

        // ⭐️ 如果正在比較模式，不要干擾比較流程
        if isComparingLanguages {
            print("⏸️ [Apple STT] 比較模式中，忽略結束信號")
            return
        }

        if isSingleLanguageMode {
            // ⭐️ 單語言模式：強制結束並重建識別
            print("🔚 [Apple STT] 單語言模式：強制結束識別")
            sourceRequest?.endAudio()

            // 短暫延遲後重建（讓 Final 結果返回）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.connectionState == .connected else { return }
                // 再次檢查是否在比較模式
                guard !self.isComparingLanguages else { return }
                self.startSingleLanguageRecognition()
            }
        } else {
            // 雙語言模式：立即發送當前最佳結果
            emitBestResult(forceFinal: true)
        }
    }

    // MARK: - Authorization

    private func handleAuthorizationStatus(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            print("✅ [Apple STT] 語音識別已授權")
            // ⭐️ 根據模式啟動不同的識別器
            if isSingleLanguageMode {
                startSingleLanguageRecognition()
            } else {
                setupRecognizers()
            }

        case .denied:
            connectionState = .error("語音識別權限被拒絕")
            _errorSubject.send("請在「設定 > 隱私權 > 語音辨識」中允許此 App")

        case .restricted:
            connectionState = .error("語音識別受限")
            _errorSubject.send("此設備不支援語音識別")

        case .notDetermined:
            connectionState = .error("語音識別權限未決定")
            _errorSubject.send("請重新啟動 App 以請求權限")

        @unknown default:
            connectionState = .error("未知權限狀態")
        }
    }

    // MARK: - Setup

    private func setupRecognizers() {
        print("🔧 [Apple STT] 設置雙語言識別器")
        print("   來源語言: \(sourceLang.displayName) (\(sourceLang.azureLocale))")
        print("   目標語言: \(targetLang.displayName) (\(targetLang.azureLocale))")

        // 創建識別器
        let sourceLocale = Locale(identifier: sourceLang.azureLocale)
        let targetLocale = Locale(identifier: targetLang.azureLocale)

        sourceRecognizer = SFSpeechRecognizer(locale: sourceLocale)
        targetRecognizer = SFSpeechRecognizer(locale: targetLocale)

        // 檢查可用性
        guard let sourceRec = sourceRecognizer else {
            connectionState = .error("來源語言識別器創建失敗")
            _errorSubject.send("不支援 \(sourceLang.displayName) 語音識別")
            return
        }

        guard let targetRec = targetRecognizer else {
            connectionState = .error("目標語言識別器創建失敗")
            _errorSubject.send("不支援 \(targetLang.displayName) 語音識別")
            return
        }

        guard sourceRec.isAvailable else {
            connectionState = .error("來源語言識別器不可用")
            _errorSubject.send("請下載 \(sourceLang.displayName) 語言包")
            return
        }

        guard targetRec.isAvailable else {
            connectionState = .error("目標語言識別器不可用")
            _errorSubject.send("請下載 \(targetLang.displayName) 語言包")
            return
        }

        // 檢查設備端識別支援
        let sourceOnDevice = sourceRec.supportsOnDeviceRecognition
        let targetOnDevice = targetRec.supportsOnDeviceRecognition

        print("   來源語言設備端識別: \(sourceOnDevice ? "✅ 支援" : "❌ 不支援")")
        print("   目標語言設備端識別: \(targetOnDevice ? "✅ 支援" : "❌ 不支援")")

        // 啟動識別任務
        startRecognitionTasks()

        // 設置任務重建計時器（避免 1 分鐘限制）
        setupTaskRebuildTimer()

        connectionState = .connected
        recognitionStartTime = Date()

        print("✅ [Apple STT] 雙語言並行識別已啟動")
    }

    private func startRecognitionTasks() {
        guard let sourceRec = sourceRecognizer,
              let targetRec = targetRecognizer else {
            return
        }

        // 創建識別請求
        sourceRequest = SFSpeechAudioBufferRecognitionRequest()
        targetRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let sourceReq = sourceRequest,
              let targetReq = targetRequest else {
            connectionState = .error("無法創建識別請求")
            return
        }

        // 配置請求
        sourceReq.shouldReportPartialResults = true
        targetReq.shouldReportPartialResults = true

        // ⭐️ 強制設備端識別（無 API 配額限制）
        if sourceRec.supportsOnDeviceRecognition {
            sourceReq.requiresOnDeviceRecognition = true
        }
        if targetRec.supportsOnDeviceRecognition {
            targetReq.requiresOnDeviceRecognition = true
        }

        // 添加上下文提示（可選，提高準確度）
        // sourceReq.contextualStrings = ["常用詞彙"]

        // 啟動來源語言識別任務
        sourceTask = sourceRec.recognitionTask(with: sourceReq) { [weak self] result, error in
            self?.handleRecognitionResult(
                result: result,
                error: error,
                isSource: true
            )
        }

        // 啟動目標語言識別任務
        targetTask = targetRec.recognitionTask(with: targetReq) { [weak self] result, error in
            self?.handleRecognitionResult(
                result: result,
                error: error,
                isSource: false
            )
        }

        print("🎙️ [Apple STT] 識別任務已啟動")
    }

    private func setupTaskRebuildTimer() {
        taskRebuildTimer?.invalidate()
        // ⭐️ 使用 .common mode，確保 UI 操作時 timer 也能觸發
        taskRebuildTimer = Timer(timeInterval: taskRebuildInterval, repeats: true) { [weak self] _ in
            self?.rebuildRecognitionTasks()
        }
        if let timer = taskRebuildTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        print("⏰ [Apple STT] 雙語言重建計時器已啟動 (\(Int(taskRebuildInterval))秒, .common mode)")
    }

    /// 重建識別任務（避免 1 分鐘超時限制）
    private func rebuildRecognitionTasks() {
        print("🔄 [Apple STT] 重建識別任務（避免超時）")

        // 發送當前結果
        emitBestResult(forceFinal: true)

        // 結束舊任務
        sourceTask?.cancel()
        targetTask?.cancel()
        sourceRequest?.endAudio()
        targetRequest?.endAudio()

        // 重置結果
        lastSourceResult = nil
        lastTargetResult = nil

        // 啟動新任務
        startRecognitionTasks()
    }

    // MARK: - Recognition Result Handling

    /// 錯誤重試計數
    private var sourceErrorCount = 0
    private var targetErrorCount = 0
    private let maxErrorRetries = 3

    private func handleRecognitionResult(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        isSource: Bool
    ) {
        let langName = isSource ? sourceLang.shortName : targetLang.shortName
        let langCode = isSource ? sourceLang.rawValue : targetLang.rawValue

        // 處理錯誤
        if let error = error {
            let nsError = error as NSError

            // 忽略取消錯誤
            if nsError.code == 1 || nsError.code == 216 {
                // 1: kAFAssistantErrorDomain - 用戶取消
                // 216: 識別被中斷
                return
            }

            // ⭐️ 處理 "No speech detected" 等可恢復錯誤
            let errorMessage = error.localizedDescription
            print("⚠️ [Apple STT/\(langName)] 錯誤: \(errorMessage) (code: \(nsError.code))")

            // ⭐️ Error 1110 "No speech detected" 是正常的
            // 表示識別器在運行，只是沒檢測到語音
            // **不要** 因為這個錯誤而重啟任務！
            if nsError.code == 1110 {
                // 追蹤連續錯誤
                consecutiveErrorCount += 1
                if consecutiveErrorCount == 1 {
                    print("ℹ️ [Apple STT] No speech detected - 等待語音輸入...")
                } else if consecutiveErrorCount % 10 == 0 {
                    print("ℹ️ [Apple STT] 持續等待語音... (已等待 \(consecutiveErrorCount) 次)")
                }

                // 如果連續太多次沒檢測到語音，可能需要重建任務
                if consecutiveErrorCount >= maxConsecutiveErrors * 2 {
                    // 但要檢查冷卻時間
                    if let lastRebuild = lastRebuildTime,
                       Date().timeIntervalSince(lastRebuild) < rebuildCooldown {
                        // 還在冷卻中，不重建
                        return
                    }

                    print("🔄 [Apple STT] 長時間無語音，嘗試重建任務...")
                    consecutiveErrorCount = 0
                    lastRebuildTime = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.rebuildRecognitionTasks()
                    }
                }
                return
            }

            // 追蹤其他錯誤次數
            if isSource {
                sourceErrorCount += 1
            } else {
                targetErrorCount += 1
            }

            // ⭐️ 只有非 1110 錯誤才考慮重啟
            if sourceErrorCount > 0 && targetErrorCount > 0 {
                // 檢查冷卻時間
                if let lastRebuild = lastRebuildTime,
                   Date().timeIntervalSince(lastRebuild) < rebuildCooldown {
                    print("⏳ [Apple STT] 重建冷卻中，跳過...")
                    return
                }

                if sourceErrorCount + targetErrorCount <= maxErrorRetries * 2 {
                    print("🔄 [Apple STT] 識別器出錯，嘗試重啟任務...")
                    lastRebuildTime = Date()
                    sourceErrorCount = 0
                    targetErrorCount = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.rebuildRecognitionTasks()
                    }
                } else {
                    print("❌ [Apple STT] 錯誤次數過多，停止重試")
                }
            }
            return
        }

        // 收到有效結果，重置所有錯誤計數
        consecutiveErrorCount = 0
        if isSource {
            sourceErrorCount = 0
        } else {
            targetErrorCount = 0
        }

        guard let result = result else { return }

        let text = result.bestTranscription.formattedString
        guard !text.isEmpty else { return }

        // 計算信心度（使用最後一個 segment 的信心度）
        let confidence = result.bestTranscription.segments.last?.confidence ?? 0
        let isFinal = result.isFinal

        // 創建結果
        let recognitionResult = RecognitionResult(
            text: text,
            confidence: confidence,
            language: langCode,
            isFinal: isFinal,
            timestamp: Date()
        )

        // 更新對應語言的結果
        if isSource {
            lastSourceResult = recognitionResult
        } else {
            lastTargetResult = recognitionResult
        }

        // ⭐️ 計算辨識延遲
        var latencyInfo = ""
        if let lastSend = lastAudioSendTime {
            let latency = Date().timeIntervalSince(lastSend) * 1000  // ms
            recognitionLatencies.append(latency)
            if recognitionLatencies.count > 20 {
                recognitionLatencies.removeFirst()
            }
            let avgLatency = recognitionLatencies.reduce(0, +) / Double(recognitionLatencies.count)
            latencyInfo = " | 延遲: \(String(format: "%.0f", latency))ms (平均: \(String(format: "%.0f", avgLatency))ms)"
        }

        // ⭐️ Interim 結果沒有信心度（Apple 的設計），只有 Final 才顯示
        let confidenceInfo = isFinal ? " (信心: \(String(format: "%.2f", confidence)))" : ""
        let finalTag = isFinal ? "✅ Final" : "⏳ Interim"
        print("🎤 [Apple STT/\(langName)] \(finalTag): \"\(text.prefix(40))\"\(confidenceInfo)\(latencyInfo)")

        // 防抖處理：合併短時間內的結果
        scheduleResultEmission(isFinal: isFinal)
    }

    private func scheduleResultEmission(isFinal: Bool) {
        debounceTimer?.invalidate()

        if isFinal {
            // Final 結果立即發送
            emitBestResult(forceFinal: true)
        } else {
            // Interim 結果防抖
            debounceTimer = Timer.scheduledTimer(
                withTimeInterval: debounceInterval,
                repeats: false
            ) { [weak self] _ in
                self?.emitBestResult(forceFinal: false)
            }
        }
    }

    /// 根據信心度選擇最佳結果並發送
    private func emitBestResult(forceFinal: Bool) {
        // 獲取兩個識別器的結果
        let sourceResult = lastSourceResult
        let targetResult = lastTargetResult

        // 選擇最佳結果
        guard let bestResult = selectBestResult(
            source: sourceResult,
            target: targetResult
        ) else {
            return
        }

        // 去重：避免重複發送相同內容
        if bestResult.text == lastEmittedText && bestResult.language == lastEmittedLanguage && !forceFinal {
            return
        }

        let isFinal = forceFinal || bestResult.isFinal

        // 更新去重記錄
        if isFinal {
            lastEmittedText = ""
            lastEmittedLanguage = ""
        } else {
            lastEmittedText = bestResult.text
            lastEmittedLanguage = bestResult.language
        }

        // 創建 TranscriptMessage
        let transcript = TranscriptMessage(
            text: bestResult.text,
            isFinal: isFinal,
            confidence: Double(bestResult.confidence),
            language: bestResult.language
        )

        // 發送到主線程
        DispatchQueue.main.async {
            self._transcriptSubject.send(transcript)
        }

        // Final 結果觸發翻譯
        if isFinal && !bestResult.text.isEmpty {
            translateText(text: bestResult.text, detectedLang: bestResult.language)

            // 重置結果
            lastSourceResult = nil
            lastTargetResult = nil
        }
    }

    /// 選擇信心度最高的結果
    private func selectBestResult(
        source: RecognitionResult?,
        target: RecognitionResult?
    ) -> RecognitionResult? {

        // ⭐️ 同時顯示兩個識別結果（方便比較）
        print("┌─────────────────────────────────────────────────────")
        if let s = source {
            print("│ 📗 [\(sourceLang.shortName)] \"\(s.text.prefix(30))\" (信心: \(String(format: "%.2f", s.confidence)))")
        } else {
            print("│ 📗 [\(sourceLang.shortName)] (無結果)")
        }
        if let t = target {
            print("│ 📘 [\(targetLang.shortName)] \"\(t.text.prefix(30))\" (信心: \(String(format: "%.2f", t.confidence)))")
        } else {
            print("│ 📘 [\(targetLang.shortName)] (無結果)")
        }

        // 只有一個結果或都沒有
        guard let source = source else {
            if target != nil {
                print("└─→ 選擇 \(targetLang.shortName)（僅有此結果）")
            } else {
                print("└─→ 兩個識別器都無結果")
            }
            return target
        }
        guard let target = target else {
            print("└─→ 選擇 \(sourceLang.shortName)（僅有此結果）")
            return source
        }

        // 信心度差異閾值（避免微小差異導致頻繁切換）
        let threshold: Float = 0.15

        // 時間差異閾值（只比較近期結果）
        let timeThreshold: TimeInterval = 0.5
        let timeDiff = abs(source.timestamp.timeIntervalSince(target.timestamp))

        // 如果時間差太大，選擇較新的
        if timeDiff > timeThreshold {
            let winner = source.timestamp > target.timestamp ? source : target
            let winnerLang = winner.language == sourceLang.rawValue ? sourceLang.shortName : targetLang.shortName
            print("└─→ ⏱️ 時間差過大，選擇較新: \(winnerLang)")
            return winner
        }

        // 比較信心度
        if source.confidence > target.confidence + threshold {
            print("└─→ 🏆 選擇 \(sourceLang.shortName)（信心 \(String(format: "%.2f", source.confidence)) > \(String(format: "%.2f", target.confidence))）")
            return source
        } else if target.confidence > source.confidence + threshold {
            print("└─→ 🏆 選擇 \(targetLang.shortName)（信心 \(String(format: "%.2f", target.confidence)) > \(String(format: "%.2f", source.confidence))）")
            return target
        } else {
            // 信心度相近，選擇文本更長的（通常更完整）
            if source.text.count >= target.text.count {
                print("└─→ 📏 信心度相近，選擇較長: \(sourceLang.shortName)（\(source.text.count) 字）")
                return source
            } else {
                print("└─→ 📏 信心度相近，選擇較長: \(targetLang.shortName)（\(target.text.count) 字）")
                return target
            }
        }
    }

    // MARK: - Translation

    /// 翻譯錯誤類型
    private enum TranslationError: Error {
        case emptyResult          // 空結果
        case similarToOriginal    // 翻譯結果與原文過於相似
        case networkError         // 網絡錯誤
        case invalidResponse      // 無效響應
    }

    /// ⭐️ 翻譯重試配置
    private let maxTranslationRetries = 3        // 最大重試次數
    private let translationRetryDelay: UInt64 = 500_000_000  // 500ms
    private let similarityThreshold: Double = 0.70  // 相似度閾值（超過則視為翻譯失敗）

    private func translateText(text: String, detectedLang: String) {
        Task {
            await callTranslationAPI(text: text, detectedLang: detectedLang)
        }
    }

    private func callTranslationAPI(text: String, detectedLang: String) async {
        // 確定翻譯方向
        let isSourceLang = detectedLang == sourceLang.rawValue
        let translateTo = isSourceLang ? targetLang.rawValue : sourceLang.rawValue

        print("🌐 [Apple STT] 翻譯: \(detectedLang) → \(translateTo)")

        // ⭐️ 重試機制
        var lastError: TranslationError?

        for attempt in 1...maxTranslationRetries {
            do {
                let (translation, segments) = try await performTranslationRequest(
                    text: text,
                    originalText: text,
                    attempt: attempt
                )

                // ⭐️ 檢查翻譯結果是否與原文過於相似
                if isTranslationTooSimilar(original: text, translation: translation) {
                    print("⚠️ [Apple STT] 第 \(attempt) 次翻譯結果與原文過於相似，重試...")
                    throw TranslationError.similarToOriginal
                }

                // ⭐️ 翻譯成功，發送結果
                DispatchQueue.main.async {
                    if let segments = segments, !segments.isEmpty {
                        self._segmentedTranslationSubject.send((text, segments))
                    }
                    self._translationSubject.send((text, translation))
                }

                print("✅ [Apple STT] 翻譯成功（第 \(attempt) 次）: \"\(translation.prefix(40))...\"")
                return

            } catch let error as TranslationError {
                lastError = error
                print("⚠️ [Apple STT] 第 \(attempt) 次翻譯失敗: \(error)")

                // 如果不是最後一次嘗試，等待後重試
                if attempt < maxTranslationRetries {
                    try? await Task.sleep(nanoseconds: translationRetryDelay)
                }
            } catch {
                print("⚠️ [Apple STT] 第 \(attempt) 次翻譯異常: \(error.localizedDescription)")

                if attempt < maxTranslationRetries {
                    try? await Task.sleep(nanoseconds: translationRetryDelay)
                }
            }
        }

        // ⭐️ 所有重試都失敗
        print("❌ [Apple STT] 翻譯 \(maxTranslationRetries) 次重試都失敗，最後錯誤: \(String(describing: lastError))")

        // 發送錯誤通知（可選：發送佔位符翻譯）
        DispatchQueue.main.async {
            self._errorSubject.send("翻譯失敗，請重試")
        }
    }

    /// ⭐️ 執行單次翻譯請求
    private func performTranslationRequest(
        text: String,
        originalText: String,
        attempt: Int
    ) async throws -> (translation: String, segments: [TranslationSegment]?) {
        // 構建 API URL
        let urlString = "https://\(serverURL)/smart-translate"
        guard let url = URL(string: urlString) else {
            throw TranslationError.networkError
        }

        // 構建請求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0  // 10 秒超時

        let body: [String: Any] = [
            "text": text,
            "sourceLang": sourceLang.rawValue,
            "targetLang": targetLang.rawValue,
            "provider": translationProvider.rawValue
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TranslationError.networkError
        }

        // 解析響應
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse
        }

        // ⭐️ 解析 LLM usage 並記錄計費
        if let usage = json["usage"] as? [String: Any] {
            let inputTokens = usage["inputTokens"] as? Int ?? 0
            let outputTokens = usage["outputTokens"] as? Int ?? 0

            if inputTokens > 0 || outputTokens > 0 {
                BillingService.shared.recordLLMUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    provider: translationProvider
                )
                print("💰 [Apple STT] LLM 計費: \(inputTokens) + \(outputTokens) tokens")
            }
        }

        // 嘗試解析 segments
        if let segmentsArray = json["segments"] as? [[String: Any]] {
            var segments: [TranslationSegment] = []
            for seg in segmentsArray {
                if let original = seg["original"] as? String,
                   let translation = seg["translation"] as? String {
                    // ⭐️ 過濾佔位符
                    guard !isErrorPlaceholder(translation) else { continue }

                    let isComplete = seg["isComplete"] as? Bool ?? true
                    segments.append(TranslationSegment(
                        original: original,
                        translation: translation,
                        isComplete: isComplete
                    ))
                }
            }

            if !segments.isEmpty {
                let fullTranslation = segments.map { $0.translation }.joined(separator: " ")

                // ⭐️ 檢查翻譯是否為空或佔位符
                guard !fullTranslation.isEmpty && !isErrorPlaceholder(fullTranslation) else {
                    throw TranslationError.emptyResult
                }

                return (fullTranslation, segments)
            }
        }

        // 回退：使用簡單翻譯
        if let translation = json["translation"] as? String {
            guard !translation.isEmpty && !isErrorPlaceholder(translation) else {
                throw TranslationError.emptyResult
            }
            return (translation, nil)
        }

        throw TranslationError.emptyResult
    }

    /// ⭐️ 檢查翻譯結果是否與原文過於相似
    /// 如果相似度 > 70%，視為翻譯失敗（可能 LLM 沒有正確翻譯）
    private func isTranslationTooSimilar(original: String, translation: String) -> Bool {
        // 正規化文本：去除空白、標點
        let normalizedOriginal = normalizeText(original)
        let normalizedTranslation = normalizeText(translation)

        // 如果翻譯後長度差異很大，肯定不同
        let lengthRatio = Double(normalizedTranslation.count) / Double(max(normalizedOriginal.count, 1))
        if lengthRatio < 0.5 || lengthRatio > 2.0 {
            return false
        }

        // 計算字符相似度
        let similarity = calculateSimilarity(normalizedOriginal, normalizedTranslation)

        if similarity > similarityThreshold {
            print("⚠️ [翻譯檢查] 相似度 \(String(format: "%.1f%%", similarity * 100)) > \(String(format: "%.0f%%", similarityThreshold * 100))")
            print("   原文: \"\(original.prefix(30))...\"")
            print("   翻譯: \"\(translation.prefix(30))...\"")
            return true
        }

        return false
    }

    /// 正規化文本（去除空白、標點）
    private func normalizeText(_ text: String) -> String {
        var result = text.lowercased()
        // 移除常見標點和空白
        let punctuation = CharacterSet.punctuationCharacters.union(.whitespaces)
        result = result.unicodeScalars.filter { !punctuation.contains($0) }.map { String($0) }.joined()
        return result
    }

    /// 計算兩個字符串的相似度（Jaccard similarity）
    private func calculateSimilarity(_ s1: String, _ s2: String) -> Double {
        guard !s1.isEmpty && !s2.isEmpty else { return 0 }

        // 使用字符集合計算 Jaccard 相似度
        let set1 = Set(s1)
        let set2 = Set(s2)

        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count

        return Double(intersection) / Double(union)
    }

    /// 檢查是否為錯誤佔位符
    private func isErrorPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 檢查 [xxx] 格式的佔位符
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return true
        }
        // 檢查常見錯誤佔位符
        let errorPatterns = ["翻譯失敗", "請稍候", "error", "failed", "loading"]
        for pattern in errorPatterns {
            if trimmed.lowercased().contains(pattern.lowercased()) {
                return true
            }
        }
        return false
    }

    // MARK: - Audio Conversion

    /// 將 PCM Int16 Data 轉換為 AVAudioPCMBuffer
    private func convertToAudioBuffer(data: Data) -> AVAudioPCMBuffer? {
        // 計算幀數（16-bit = 2 bytes per sample）
        let frameCount = UInt32(data.count) / 2
        guard frameCount > 0 else { return nil }

        // 創建 buffer
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: frameCount
        ) else {
            return nil
        }
        buffer.frameLength = frameCount

        // 轉換 Int16 → Float32
        data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let floatChannelData = buffer.floatChannelData else {
                return
            }

            let floatPtr = floatChannelData[0]
            for i in 0..<Int(frameCount) {
                floatPtr[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        return buffer
    }

    // MARK: - ⭐️ 自動語言切換（經濟模式）

    /// 開始語言比較流程
    /// 切換到另一種語言，用緩衝區音頻重新識別
    private func startLanguageComparison() {
        guard audioRingBuffer.hasData else {
            print("⚠️ [自動切換] 緩衝區無數據，跳過比較")
            finalizeComparison()
            return
        }

        isComparingLanguages = true
        let originalLanguage = currentActiveLanguage
        let otherLanguage = (currentActiveLanguage == sourceLang) ? targetLang : sourceLang

        print("🔄 [自動切換] 切換到 \(otherLanguage.shortName) 進行比較...")
        print("   📼 使用緩衝區 \(String(format: "%.1f", audioRingBuffer.bufferedDuration)) 秒音頻")

        // 獲取緩衝區音頻
        let bufferedAudio = audioRingBuffer.readAll()

        // 停止當前識別
        stopSingleLanguageRecognition()

        // 切換語言
        currentActiveLanguage = otherLanguage

        // 創建新的識別任務
        startSingleLanguageRecognition()

        // ⭐️ 重要：等待識別器完全準備好再發送音頻
        // startSingleLanguageRecognition() 是異步的，需要足夠時間讓：
        // 1. SFSpeechRecognizer 初始化
        // 2. recognitionTask 創建並啟動
        // 3. 回調綁定完成
        // 0.1 秒不夠，改為 0.5 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isComparingLanguages else { return }
            print("✅ [自動切換] 識別器準備完成，開始發送緩衝音頻")
            self.resendBufferedAudio(bufferedAudio)
        }
    }

    /// 重新發送緩衝區音頻
    private func resendBufferedAudio(_ data: Data) {
        guard let buffer = convertToAudioBuffer(data: data) else {
            print("❌ [自動切換] 緩衝區音頻轉換失敗")
            finalizeComparison()
            return
        }

        let audioDuration = Double(data.count) / Double(16000 * 2)  // 16kHz, 16-bit
        print("📤 [自動切換] 重新發送 \(data.count) bytes 緩衝音頻 (約 \(String(format: "%.1f", audioDuration))秒)")

        // 發送到識別器
        if let request = sourceRequest {
            request.append(buffer)
            print("✅ [自動切換] 音頻已發送到識別器")

            // ⭐️ 立即調用 endAudio() 觸發 Final
            print("🔚 [自動切換] 調用 endAudio() 觸發 Final")
            request.endAudio()
        } else {
            print("❌ [自動切換] sourceRequest 為 nil，無法發送音頻")
            finalizeComparison()
            return
        }

        // 設置超時（等待 Final 結果，最多 5 秒）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isComparingLanguages else { return }
            print("⏱️ [自動切換] 等待 Final 超時，使用現有結果")
            self.finalizeComparison()
        }
    }

    /// 處理比較模式下的識別結果
    private func handleComparisonResult(text: String, confidence: Float, isFinal: Bool) {
        let tag = isFinal ? "Final" : "Interim"
        print("📊 [自動切換] 收到比較結果 (\(tag)): \(currentActiveLanguage.shortName) = \"\(text.prefix(30))\" (信心: \(String(format: "%.2f", confidence)))")

        // 儲存結果（Final 結果覆蓋 Interim）
        comparisonResults[currentActiveLanguage] = (text: text, confidence: confidence)

        // 只有 Final 結果才結束比較
        if isFinal {
            finalizeComparison()
        }
    }

    /// 完成比較，選擇最佳結果
    private func finalizeComparison() {
        isComparingLanguages = false

        // 比較結果
        print("┌─────────────────────────────────────────────────────")
        print("│ 📊 [比較] 語言比較結果:")

        // ⭐️ 比較顯示模式：發送所有結果讓 UI 顯示
        if isComparisonDisplayMode {
            var allResults: [(lang: Language, text: String, confidence: Float, isFinal: Bool)] = []

            for (lang, result) in comparisonResults {
                let isFinal = result.confidence >= 0
                let displayConfidence = result.confidence < 0 ? "N/A" : String(format: "%.2f", result.confidence)
                let tag = isFinal ? "Final" : "Interim"
                print("│   \(lang.shortName): \"\(result.text.prefix(30))\" (\(tag), 信心: \(displayConfidence))")

                allResults.append((
                    lang: lang,
                    text: result.text,
                    confidence: result.confidence < 0 ? 0 : result.confidence,
                    isFinal: isFinal
                ))
            }

            print("└─────────────────────────────────────────────────────")

            // 發送比較結果到 UI
            DispatchQueue.main.async {
                self.onComparisonResults?(allResults)
            }

            // 清空比較結果
            comparisonResults.removeAll()
            audioRingBuffer.clear()

            // 恢復到來源語言
            stopSingleLanguageRecognition()
            currentActiveLanguage = sourceLang
            startSingleLanguageRecognition()
            return
        }

        // ⭐️ 自動切換模式：選擇最佳結果
        var bestLanguage: Language = currentActiveLanguage
        var bestText: String = ""
        var bestConfidence: Float = -999  // 用於比較，-1 是 Interim 標記

        for (lang, result) in comparisonResults {
            let isFinal = result.confidence >= 0
            let isReliableFinal = isFinal && result.confidence >= unreliableFinalThreshold
            let tag = isFinal ? (isReliableFinal ? "Final" : "Final(低信心)") : "Interim"
            let displayConfidence = result.confidence < 0 ? "N/A" : String(format: "%.2f", result.confidence)
            print("│   \(lang.shortName): \"\(result.text.prefix(25))\" (\(tag), 信心: \(displayConfidence))")

            // ⭐️ 改進的比較邏輯：
            // 1. 可靠 Final (信心 >= 0.30) 優先
            // 2. 不可靠 Final (信心 < 0.30) 和 Interim 視為同等，按文字長度比較
            // 3. 同為可靠 Final 時，比較信心度

            let currentIsFinal = result.confidence >= 0
            let currentIsReliable = currentIsFinal && result.confidence >= unreliableFinalThreshold
            let bestIsFinal = bestConfidence >= 0
            let bestIsReliable = bestIsFinal && bestConfidence >= unreliableFinalThreshold

            let isBetter: Bool
            if currentIsReliable && !bestIsReliable {
                // 新結果是可靠 Final，舊結果不是
                isBetter = true
            } else if !currentIsReliable && bestIsReliable {
                // 新結果不可靠，舊結果是可靠 Final
                isBetter = false
            } else if currentIsReliable && bestIsReliable {
                // 兩個都是可靠 Final，比較信心度
                isBetter = result.confidence > bestConfidence
            } else {
                // 兩個都不可靠（Interim 或低信心 Final），選擇文字較長的
                isBetter = result.text.count > bestText.count
            }

            if isBetter {
                bestLanguage = lang
                bestText = result.text
                bestConfidence = result.confidence
            }
        }

        let displayBestConfidence = bestConfidence < 0 ? "N/A" : String(format: "%.2f", bestConfidence)
        print("│ 🏆 選擇: \(bestLanguage.shortName) (信心: \(displayBestConfidence))")
        print("└─────────────────────────────────────────────────────")

        // 如果最佳語言不是當前語言，切換
        if bestLanguage != currentActiveLanguage {
            print("🔄 [自動切換] 切換到 \(bestLanguage.shortName)")
            stopSingleLanguageRecognition()
            currentActiveLanguage = bestLanguage
            startSingleLanguageRecognition()
        }

        // ⭐️ 通知 UI 更新（無論是否切換，都要同步狀態）
        DispatchQueue.main.async {
            self.onLanguageSwitched?(bestLanguage)
        }

        // 清空比較結果
        comparisonResults.removeAll()

        // 清空緩衝區
        audioRingBuffer.clear()

        // 發送最佳結果
        if !bestText.isEmpty {
            // 使用最佳信心度，如果是負數（Interim）則設為 0.5
            let displayConfidence = bestConfidence < 0 ? 0.5 : Double(bestConfidence)

            let transcript = TranscriptMessage(
                text: bestText,
                isFinal: true,
                confidence: displayConfidence,
                language: bestLanguage.rawValue
            )

            DispatchQueue.main.async {
                self._transcriptSubject.send(transcript)
            }

            // 觸發翻譯
            translateText(text: bestText, detectedLang: bestLanguage.rawValue)

            // 回調通知
            onLanguageComparisonComplete?(bestLanguage, bestText, bestConfidence)
        }
    }

    // MARK: - ⭐️ 經濟模式雙語言批量比較

    /// 雙語言比較結果暫存
    private var dualComparisonResults: [Language: (text: String, confidence: Float, isFinal: Bool)] = [:]
    private var dualComparisonPendingLanguages: Set<Language> = []

    /// 清空音頻緩衝區
    func clearAudioBuffer() {
        audioRingBuffer.clear()
        print("🗑️ [Apple STT] 音頻緩衝區已清空")
    }

    /// 開始雙語言批量比較（經濟模式專用）
    /// 用緩衝區音頻分別送給兩個語言的識別器，等待兩個 Final 結果
    func startDualLanguageComparison() {
        guard audioRingBuffer.hasData else {
            print("⚠️ [雙語言比較] 緩衝區無數據")
            return
        }

        let bufferedAudio = audioRingBuffer.readAll()
        let audioDuration = Double(bufferedAudio.count) / Double(16000 * 2)
        print("🔬 [雙語言比較] 開始比較，音頻: \(String(format: "%.1f", audioDuration))秒")

        // 重置比較狀態
        dualComparisonResults.removeAll()
        dualComparisonPendingLanguages = [sourceLang, targetLang]

        // 停止當前識別
        stopSingleLanguageRecognition()

        // 依序識別兩種語言
        recognizeWithLanguage(sourceLang, audio: bufferedAudio) { [weak self] in
            guard let self = self else { return }
            // 第一個語言完成，開始第二個
            self.recognizeWithLanguage(self.targetLang, audio: bufferedAudio) { [weak self] in
                // 兩個都完成
                self?.finalizeDualComparison()
            }
        }
    }

    /// 用指定語言識別音頻
    private func recognizeWithLanguage(_ language: Language, audio: Data, completion: @escaping () -> Void) {
        print("🎯 [雙語言比較] 開始識別: \(language.shortName)")

        let locale = Locale(identifier: language.azureLocale)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            print("❌ [雙語言比較] \(language.shortName) 識別器不可用")
            dualComparisonResults[language] = (text: "(不支援)", confidence: 0, isFinal: true)
            dualComparisonPendingLanguages.remove(language)
            completion()
            return
        }

        // 創建識別請求
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // 轉換音頻
        guard let buffer = convertToAudioBuffer(data: audio) else {
            print("❌ [雙語言比較] 音頻轉換失敗")
            dualComparisonResults[language] = (text: "(轉換失敗)", confidence: 0, isFinal: true)
            dualComparisonPendingLanguages.remove(language)
            completion()
            return
        }

        // 追蹤是否已完成
        var hasCompleted = false

        // 啟動識別任務
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                let nsError = error as NSError
                // 忽略取消錯誤
                if nsError.code != 1 && nsError.code != 216 {
                    print("⚠️ [雙語言比較/\(language.shortName)] 錯誤: \(error.localizedDescription)")
                }
            }

            if let result = result {
                let text = result.bestTranscription.formattedString
                let confidence = result.bestTranscription.segments.last?.confidence ?? 0
                let isFinal = result.isFinal

                // 更新結果
                self.dualComparisonResults[language] = (text: text, confidence: confidence, isFinal: isFinal)

                let tag = isFinal ? "✅ Final" : "⏳ Interim"
                print("📊 [雙語言比較/\(language.shortName)] \(tag): \"\(text.prefix(30))\" (信心: \(String(format: "%.2f", confidence)))")

                // Final 結果時完成
                if isFinal && !hasCompleted {
                    hasCompleted = true
                    self.dualComparisonPendingLanguages.remove(language)
                    completion()
                }
            }
        }

        // 發送音頻
        request.append(buffer)
        print("📤 [雙語言比較/\(language.shortName)] 已發送 \(audio.count) bytes")

        // 調用 endAudio 觸發 Final
        request.endAudio()
        print("🔚 [雙語言比較/\(language.shortName)] 已調用 endAudio()")

        // 設置超時（5 秒）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, !hasCompleted else { return }
            hasCompleted = true
            print("⏱️ [雙語言比較/\(language.shortName)] 超時，使用現有結果")
            task.cancel()
            self.dualComparisonPendingLanguages.remove(language)
            completion()
        }
    }

    /// 完成雙語言比較，選擇最佳結果並觸發翻譯
    private func finalizeDualComparison() {
        print("┌─────────────────────────────────────────────────────")
        print("│ 🔬 [雙語言比較] 結果:")

        // ⭐️ 收集所有結果並選擇最佳
        var allResults: [(lang: Language, text: String, confidence: Float, isFinal: Bool)] = []
        var bestLang: Language = sourceLang
        var bestText: String = ""
        var bestConfidence: Float = -1

        for (lang, result) in dualComparisonResults {
            let tag = result.isFinal ? "Final" : "Interim"
            print("│   \(lang.shortName): \"\(result.text.prefix(30))\" (\(tag), 信心: \(String(format: "%.2f", result.confidence)))")

            allResults.append((
                lang: lang,
                text: result.text,
                confidence: result.confidence,
                isFinal: result.isFinal
            ))

            // ⭐️ 選擇信心水準最高的
            // 如果信心度相同，選擇文本較長的（通常更完整）
            let isBetter: Bool
            if result.confidence > bestConfidence + 0.05 {
                // 信心度明顯更高
                isBetter = true
            } else if result.confidence < bestConfidence - 0.05 {
                // 信心度明顯更低
                isBetter = false
            } else {
                // 信心度相近，選擇文本較長的
                isBetter = result.text.count > bestText.count
            }

            if isBetter && !result.text.isEmpty {
                bestLang = lang
                bestText = result.text
                bestConfidence = result.confidence
            }
        }

        print("│ 🏆 選擇: \(bestLang.shortName) (信心: \(String(format: "%.2f", bestConfidence)))")
        print("└─────────────────────────────────────────────────────")

        // ⭐️ 更新當前活動語言（下次錄音預設用這個語言）
        currentActiveLanguage = bestLang

        // 清空緩衝區
        audioRingBuffer.clear()

        // ⭐️ 如果有有效結果，發送並觸發翻譯
        if !bestText.isEmpty {
            // 創建 TranscriptMessage
            let transcript = TranscriptMessage(
                text: bestText,
                isFinal: true,
                confidence: Double(bestConfidence),
                language: bestLang.rawValue
            )

            // 發送到主線程
            DispatchQueue.main.async {
                self._transcriptSubject.send(transcript)

                // ⭐️ 通知 ViewModel 選中的語言和結果
                self.onBestComparisonResult?(bestLang, bestText, bestConfidence)
            }

            // ⭐️ 觸發翻譯 API
            translateText(text: bestText, detectedLang: bestLang.rawValue)
        }

        // 恢復識別器（準備下一次錄音）
        startSingleLanguageRecognition()
    }

    // MARK: - Static Methods

    /// 檢查語言是否支援 Apple STT
    static func isLanguageSupported(_ language: Language) -> Bool {
        let locale = Locale(identifier: language.azureLocale)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return false
        }
        return recognizer.isAvailable
    }

    /// 檢查語言是否支援設備端識別
    static func supportsOnDeviceRecognition(_ language: Language) -> Bool {
        let locale = Locale(identifier: language.azureLocale)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return false
        }
        return recognizer.supportsOnDeviceRecognition
    }

    /// 列出所有支援的語言
    static func listSupportedLanguages() {
        print("📋 [Apple STT] 支援的語言列表:")
        for lang in Language.allCases {
            if lang == .auto { continue }
            let supported = isLanguageSupported(lang)
            let onDevice = supportsOnDeviceRecognition(lang)
            let status = supported ? (onDevice ? "✅ 設備端" : "☁️ 雲端") : "❌ 不支援"
            print("   \(lang.displayName): \(status)")
        }
    }
}
