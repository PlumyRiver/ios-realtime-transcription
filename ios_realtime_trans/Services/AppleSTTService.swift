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

    /// 連接狀態
    private(set) var connectionState: WebSocketConnectionState = .disconnected

    /// 翻譯模型選擇
    var translationProvider: TranslationProvider = .gemini

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

        connectionState = .connecting

        // 請求語音識別權限
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.handleAuthorizationStatus(status)
            }
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

        // 重置狀態
        lastSourceResult = nil
        lastTargetResult = nil
        lastEmittedText = ""
        lastEmittedLanguage = ""

        connectionState = .disconnected
    }

    func sendAudio(data: Data) {
        guard connectionState == .connected else { return }

        // 轉換 PCM Int16 → AVAudioPCMBuffer
        guard let buffer = convertToAudioBuffer(data: data) else {
            return
        }

        // 發送給兩個識別器
        sourceRequest?.append(buffer)
        targetRequest?.append(buffer)

        // 統計音頻時長
        let duration = Double(buffer.frameLength) / 16000.0
        totalAudioDuration += duration
    }

    func sendEndUtterance() {
        // Apple STT 會自動檢測語音結束
        // 但我們可以強制結束當前識別並重建任務
        print("📤 [Apple STT] 收到結束語句信號")

        // 立即發送當前最佳結果（如果有）
        emitBestResult(forceFinal: true)
    }

    // MARK: - Authorization

    private func handleAuthorizationStatus(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            print("✅ [Apple STT] 語音識別已授權")
            setupRecognizers()

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
        taskRebuildTimer = Timer.scheduledTimer(
            withTimeInterval: taskRebuildInterval,
            repeats: true
        ) { [weak self] _ in
            self?.rebuildRecognitionTasks()
        }
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

    private func handleRecognitionResult(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        isSource: Bool
    ) {
        let langName = isSource ? sourceLang.shortName : targetLang.shortName
        let langCode = isSource ? sourceLang.rawValue : targetLang.rawValue

        // 處理錯誤
        if let error = error {
            // 忽略取消錯誤
            if (error as NSError).code == 1 || (error as NSError).code == 216 {
                // 1: kAFAssistantErrorDomain - 用戶取消
                // 216: 識別被中斷
                return
            }
            print("⚠️ [Apple STT/\(langName)] 錯誤: \(error.localizedDescription)")
            return
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

        // Debug 輸出
        let finalTag = isFinal ? "Final" : "Interim"
        print("🎤 [Apple STT/\(langName)] \(finalTag): \"\(text.prefix(40))\" (信心: \(String(format: "%.2f", confidence)))")

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

        // 只有一個結果
        guard let source = source else {
            return target
        }
        guard let target = target else {
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
            print("⏱️ [Apple STT] 選擇較新結果: \(winner.language)")
            return winner
        }

        // 比較信心度
        if source.confidence > target.confidence + threshold {
            print("🏆 [Apple STT] 選擇來源語言 (\(sourceLang.shortName)): 信心 \(String(format: "%.2f", source.confidence)) > \(String(format: "%.2f", target.confidence))")
            return source
        } else if target.confidence > source.confidence + threshold {
            print("🏆 [Apple STT] 選擇目標語言 (\(targetLang.shortName)): 信心 \(String(format: "%.2f", target.confidence)) > \(String(format: "%.2f", source.confidence))")
            return target
        } else {
            // 信心度相近，選擇文本更長的（通常更完整）
            if source.text.count >= target.text.count {
                print("📏 [Apple STT] 信心度相近，選擇較長文本: \(sourceLang.shortName)")
                return source
            } else {
                print("📏 [Apple STT] 信心度相近，選擇較長文本: \(targetLang.shortName)")
                return target
            }
        }
    }

    // MARK: - Translation

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

        // 構建 API URL
        let urlString = "https://\(serverURL)/smart-translate"
        guard let url = URL(string: urlString) else {
            print("❌ [Apple STT] 無效的翻譯 URL")
            return
        }

        // 構建請求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "sourceLang": sourceLang.rawValue,
            "targetLang": targetLang.rawValue,
            "provider": translationProvider.rawValue
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ [Apple STT] 翻譯 API 錯誤")
                return
            }

            // 解析響應
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 嘗試解析 segments
                if let segmentsArray = json["segments"] as? [[String: Any]] {
                    var segments: [TranslationSegment] = []
                    for seg in segmentsArray {
                        if let original = seg["original"] as? String,
                           let translation = seg["translation"] as? String {
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

                        DispatchQueue.main.async {
                            self._segmentedTranslationSubject.send((text, segments))
                            self._translationSubject.send((text, fullTranslation))
                        }

                        print("✅ [Apple STT] 翻譯完成: \"\(fullTranslation.prefix(40))...\"")
                        return
                    }
                }

                // 回退：使用簡單翻譯
                if let translation = json["translation"] as? String {
                    DispatchQueue.main.async {
                        self._translationSubject.send((text, translation))
                    }
                    print("✅ [Apple STT] 翻譯完成: \"\(translation.prefix(40))...\"")
                }
            }

        } catch {
            print("❌ [Apple STT] 翻譯請求失敗: \(error.localizedDescription)")
        }
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
