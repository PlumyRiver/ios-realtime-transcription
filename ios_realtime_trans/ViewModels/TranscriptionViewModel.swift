//
//  TranscriptionViewModel.swift
//  ios_realtime_trans
//
//  轉錄視圖模型：管理錄音、WebSocket 和 UI 狀態
//

import Foundation
import Combine

/// 連接狀態
enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case recording
    case error(String)

    var displayText: String {
        switch self {
        case .disconnected:
            return "準備就緒，點擊「開始錄音」開始轉錄"
        case .connecting:
            return "正在連接伺服器..."
        case .connected:
            return "已連接，準備錄音"
        case .recording:
            return "錄音中... 請開始說話"
        case .error(let message):
            return "錯誤: \(message)"
        }
    }

    var statusType: StatusType {
        switch self {
        case .disconnected, .connected:
            return .idle
        case .connecting:
            return .processing
        case .recording:
            return .recording
        case .error:
            return .error
        }
    }

    enum StatusType {
        case idle, recording, processing, error
    }
}

@Observable
final class TranscriptionViewModel {

    // MARK: - Published Properties

    var sourceLang: Language = .zh
    var targetLang: Language = .en
    var status: ConnectionStatus = .disconnected

    var transcripts: [TranscriptMessage] = []
    var interimTranscript: TranscriptMessage?

    var transcriptCount: Int = 0
    var wordCount: Int = 0
    var recordingDuration: Int = 0

    var isRecording: Bool {
        if case .recording = status {
            return true
        }
        return false
    }

    /// 擴音模式狀態（默認開啟，提升 TTS 音量）
    var isSpeakerMode: Bool = true {
        didSet {
            // 同步到 AudioManager
            audioManager.isSpeakerMode = isSpeakerMode
        }
    }

    /// 自動播放翻譯（TTS）
    var autoPlayTTS: Bool = true

    /// TTS 播放中
    var isPlayingTTS: Bool {
        audioManager.isPlayingTTS
    }

    // MARK: - Configuration

    /// 伺服器 URL（Cloud Run 部署的服務）
    var serverURL: String = "chirp3-ios-api-1027448899164.asia-east1.run.app"

    // MARK: - Private Properties

    private let webSocketService = WebSocketService()

    /// ⭐️ 使用統一的 AudioManager（回音消除核心）
    private let audioManager = AudioManager.shared

    /// TTS 服務
    private let ttsService = AzureTTSService()

    /// TTS 播放隊列
    private var ttsQueue: [(text: String, lang: String)] = []
    private var isProcessingTTS = false
    /// ⭐️ 當前正在合成的文本（用於去重）
    private var currentSynthesizingText: String?

    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?
    private var startTime: Date?

    // MARK: - Initialization

    init() {
        setupSubscriptions()
    }

    // MARK: - Public Methods

    /// 是否正在處理連接/斷開
    private var isProcessing = false

    /// 切換錄音狀態
    @MainActor
    func toggleRecording() async {
        // 防止重複觸發
        guard !isProcessing else {
            print("⚠️ 正在處理中，忽略重複觸發")
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    /// 清除所有轉錄記錄
    func clearTranscripts() {
        transcripts.removeAll()
        interimTranscript = nil
        transcriptCount = 0
        wordCount = 0
    }

    // MARK: - Private Methods

    /// 開始錄音
    @MainActor
    private func startRecording() async {
        // 請求麥克風權限
        let granted = await audioManager.requestPermission()
        guard granted else {
            status = .error("請允許使用麥克風")
            return
        }

        status = .connecting

        print("🔌 開始連接伺服器: \(serverURL)")

        // 連接 WebSocket
        webSocketService.connect(
            serverURL: serverURL,
            sourceLang: sourceLang,
            targetLang: targetLang
        )

        // 等待連接成功（最多等待 10 秒）
        print("⏳ 等待連接...")
        let connectionResult = await waitForConnection(timeout: 10.0)
        print("📡 連接結果: \(connectionResult), 狀態: \(webSocketService.connectionState)")

        guard connectionResult else {
            if case .error(let message) = webSocketService.connectionState {
                print("❌ 連接錯誤: \(message)")
                status = .error(message)
            } else {
                print("❌ 連接逾時")
                status = .error("連接逾時，請檢查網路或伺服器狀態")
            }
            webSocketService.disconnect()
            return
        }

        print("✅ WebSocket 連接成功")

        // ⭐️ 使用統一的 AudioManager 開始錄音（內建回音消除）
        do {
            // 設置擴音模式
            audioManager.isSpeakerMode = isSpeakerMode

            try audioManager.startRecording()

            print("🔊 [AudioManager] 全雙工模式啟動（錄音 + TTS 播放共用 Engine，AEC 啟用）")

            status = .recording
            startDurationTimer()
        } catch {
            status = .error(error.localizedDescription)
            webSocketService.disconnect()
        }
    }

    /// 停止錄音
    @MainActor
    private func stopRecording() {
        stopDurationTimer()

        // ⭐️ 使用統一的 AudioManager
        audioManager.stopRecording()
        audioManager.stopTTS()

        webSocketService.disconnect()
        status = .disconnected

        // 清除 interim 和 TTS 隊列
        interimTranscript = nil
        ttsQueue.removeAll()
        isProcessingTTS = false
    }

    /// 切換擴音模式
    func toggleSpeakerMode() {
        isSpeakerMode.toggle()
        // AudioManager 會通過 didSet 自動同步
        print("🔊 [ViewModel] 擴音模式: \(isSpeakerMode ? "開啟" : "關閉")")
    }

    /// 設定 Combine 訂閱
    private func setupSubscriptions() {
        // ⭐️ 訂閱音頻數據（來自統一的 AudioManager）
        audioManager.audioDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.webSocketService.sendAudio(data: data)
            }
            .store(in: &cancellables)

        // 訂閱轉錄結果
        webSocketService.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.handleTranscript(transcript)
            }
            .store(in: &cancellables)

        // 訂閱翻譯結果
        webSocketService.translationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sourceText, translatedText) in
                self?.handleTranslation(sourceText: sourceText, translatedText: translatedText)
            }
            .store(in: &cancellables)

        // 訂閱錯誤
        webSocketService.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                self?.status = .error(errorMessage)
            }
            .store(in: &cancellables)

        // ⭐️ TTS 播放完成回調（播放隊列中的下一個）
        audioManager.onTTSPlaybackFinished = { [weak self] in
            self?.processNextTTS()
        }
    }

    /// 處理轉錄結果
    private func handleTranscript(_ transcript: TranscriptMessage) {
        if transcript.isFinal {
            // 最終結果：添加到列表末尾（最新的在下面）
            transcripts.append(transcript)
            interimTranscript = nil
            updateStats()
        } else {
            // 中間結果：更新 interim
            interimTranscript = transcript
        }
    }

    /// 處理翻譯結果
    private func handleTranslation(sourceText: String, translatedText: String) {
        // 找到對應的轉錄並添加翻譯
        var shouldPlayTTS = false

        if let index = transcripts.firstIndex(where: { $0.text == sourceText }) {
            // ⭐️ 只有當翻譯不存在時才播放 TTS（避免 interim + final 翻譯都觸發）
            let existingTranslation = transcripts[index].translation
            if existingTranslation == nil || existingTranslation?.isEmpty == true {
                shouldPlayTTS = true
            }
            transcripts[index].translation = translatedText
        } else if interimTranscript?.text == sourceText {
            interimTranscript?.translation = translatedText
            // interim 結果不播放 TTS
        }

        // ⭐️ 自動播放 TTS（僅播放一次，避免重複）
        if autoPlayTTS && shouldPlayTTS {
            // 判斷翻譯的目標語言
            let targetLangCode = getTargetLanguageCode(for: translatedText)
            enqueueTTS(text: translatedText, languageCode: targetLangCode)
        }
    }

    // MARK: - TTS Methods

    /// 獲取翻譯結果的目標語言代碼
    private func getTargetLanguageCode(for text: String) -> String {
        // 簡單判斷：如果是中文字符多，則是中文
        let chineseCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        if chineseCount > text.count / 3 {
            return "zh-TW"
        }
        return "en-US"
    }

    /// 將文本加入 TTS 播放隊列
    func enqueueTTS(text: String, languageCode: String) {
        guard !text.isEmpty else { return }

        // ⭐️ 去重：檢查隊列中是否已有相同文本
        if ttsQueue.contains(where: { $0.text == text }) {
            print("⚠️ [TTS Queue] 忽略重複文本（已在隊列中）: \"\(text.prefix(20))...\"")
            return
        }

        // ⭐️ 去重：檢查當前正在合成的是否是相同文本
        if currentSynthesizingText == text {
            print("⚠️ [TTS Queue] 忽略重複文本（正在合成）: \"\(text.prefix(20))...\"")
            return
        }

        // ⭐️ 去重：檢查當前正在播放的是否是相同文本
        if audioManager.currentTTSText == text {
            print("⚠️ [TTS Queue] 忽略重複文本（正在播放）: \"\(text.prefix(20))...\"")
            return
        }

        ttsQueue.append((text: text, lang: languageCode))
        print("📥 [TTS Queue] 加入隊列: \"\(text.prefix(20))...\" (\(languageCode))")

        // 如果沒有正在處理，開始處理
        if !isProcessingTTS {
            processNextTTS()
        }
    }

    /// 處理下一個 TTS
    private func processNextTTS() {
        guard !ttsQueue.isEmpty else {
            isProcessingTTS = false
            currentSynthesizingText = nil  // 清除
            return
        }

        isProcessingTTS = true
        let item = ttsQueue.removeFirst()

        // ⭐️ 記錄當前正在合成的文本（用於去重）
        currentSynthesizingText = item.text

        Task {
            do {
                print("🎙️ [TTS] 合成中: \"\(item.text.prefix(30))...\"")

                // 獲取音頻數據
                let audioData = try await ttsService.synthesize(
                    text: item.text,
                    languageCode: item.lang
                )

                // ⭐️ 使用 AudioManager 播放（同一 Engine，AEC 啟用）
                try audioManager.playTTS(audioData: audioData, text: item.text)

                // 播放開始後清除合成文本（currentTTSText 已接管）
                currentSynthesizingText = nil

                print("▶️ [TTS] 播放中（錄音繼續，回音消除啟用）")

            } catch {
                print("❌ [TTS] 錯誤: \(error.localizedDescription)")
                currentSynthesizingText = nil  // 清除
                // 繼續處理下一個
                processNextTTS()
            }
        }
    }

    /// 停止當前 TTS 播放
    func stopCurrentTTS() {
        audioManager.stopTTS()
        ttsQueue.removeAll()
        isProcessingTTS = false
    }

    /// 更新統計數據
    private func updateStats() {
        transcriptCount = transcripts.filter { $0.isFinal }.count
        wordCount = transcripts.reduce(0) { $0 + $1.text.count }
    }

    /// 開始計時器
    private func startDurationTimer() {
        startTime = Date()
        recordingDuration = 0

        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.startTime else { return }
            Task { @MainActor in
                self.recordingDuration = Int(Date().timeIntervalSince(startTime))
            }
        }
    }

    /// 停止計時器
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    /// 等待 WebSocket 連接完成
    /// - Parameter timeout: 最大等待時間（秒）
    /// - Returns: 是否連接成功
    private func waitForConnection(timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        let checkInterval: UInt64 = 100_000_000 // 100ms in nanoseconds

        while Date().timeIntervalSince(startTime) < timeout {
            // 檢查連接狀態
            switch webSocketService.connectionState {
            case .connected:
                return true
            case .error:
                return false
            case .connecting, .disconnected:
                // 繼續等待
                try? await Task.sleep(nanoseconds: checkInterval)
            }
        }

        // 超時
        return false
    }
}
