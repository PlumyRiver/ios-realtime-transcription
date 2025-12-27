//
//  TranscriptionViewModel.swift
//  ios_realtime_trans
//
//  轉錄視圖模型：管理錄音、WebSocket 和 UI 狀態
//

import Foundation
import Combine
import AVFoundation

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

    /// ⭐️ 是否在通話中（連接中或錄音中都算通話中，讓 UI 立即切換）
    var isRecording: Bool {
        switch status {
        case .connecting, .recording:
            return true
        default:
            return false
        }
    }

    /// 擴音模式狀態（默認開啟，提升 TTS 音量）
    var isSpeakerMode: Bool = true {
        didSet {
            // 同步到 AudioManager
            audioManager.isSpeakerMode = isSpeakerMode
        }
    }

    /// TTS 播放模式（四段切換）
    var ttsPlaybackMode: TTSPlaybackMode = .all

    /// ⭐️ TTS 服務商（Azure 或 Apple）
    var ttsProvider: TTSProvider = .azure

    /// 自動播放翻譯（TTS）- 計算屬性，向後兼容
    var autoPlayTTS: Bool {
        get { ttsPlaybackMode != .muted }
        set { ttsPlaybackMode = newValue ? .all : .muted }
    }

    /// ⭐️ TTS 音量（0.0 ~ 1.0，對應 0 ~ 36 dB 總增益，WebRTC AEC3 無 AGC 限制）
    var ttsVolume: Float {
        get { audioManager.volumePercent }
        set { audioManager.volumePercent = newValue }
    }

    /// TTS 播放中
    var isPlayingTTS: Bool {
        switch ttsProvider {
        case .azure:
            return audioManager.isPlayingTTS
        case .apple:
            return appleTTSService.isPlaying
        }
    }

    /// ⭐️ 當前正在播放的 TTS 文本
    var currentPlayingTTSText: String? {
        switch ttsProvider {
        case .azure:
            return audioManager.currentTTSText
        case .apple:
            return appleTTSService.currentText
        }
    }

    /// ⭐️ Push-to-Talk：是否正在按住說話
    var isPushToTalkActive: Bool {
        !audioManager.isManualSendingPaused
    }

    /// ⭐️ 輸入模式：PTT（按住說話）或 VAD（持續監聽）
    enum InputMode: String {
        case ptt = "ptt"  // Push-to-Talk：按住說話
        case vad = "vad"  // Voice Activity Detection：持續監聽
    }

    var inputMode: InputMode = .ptt {
        didSet {
            if oldValue != inputMode {
                handleInputModeChange()
            }
        }
    }

    /// 是否為持續監聽模式
    var isVADMode: Bool {
        inputMode == .vad
    }

    // MARK: - Configuration

    /// 伺服器 URL（Cloud Run 部署的服務）
    var serverURL: String = "chirp3-ios-api-1027448899164.asia-east1.run.app"

    /// ⭐️ STT 提供商選擇（預設 ElevenLabs，延遲更低）
    var sttProvider: STTProvider = .elevenLabs {
        didSet {
            if oldValue != sttProvider {
                print("🔄 [STT] 切換提供商: \(oldValue.displayName) → \(sttProvider.displayName)")
                // 如果正在錄音，需要重新連接
                if isRecording {
                    Task { @MainActor in
                        stopRecording()
                        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s 延遲
                        await startRecording()
                    }
                }
            }
        }
    }

    /// ⭐️ 翻譯模型選擇（預設 Gemini 3 Flash）
    var translationProvider: TranslationProvider = .gemini {
        didSet {
            if oldValue != translationProvider {
                print("🔄 [翻譯] 切換模型: \(oldValue.displayName) → \(translationProvider.displayName)")
                // 更新各 STT 服務的翻譯模型
                elevenLabsService.translationProvider = translationProvider
                appleSTTService.translationProvider = translationProvider
            }
        }
    }

    // MARK: - VAD 設定

    /// ⭐️ VAD 閾值（0.0 ~ 1.0）
    /// 越高越嚴格，需要更大聲音才會觸發語音識別
    var vadThreshold: Float = 0.3 {
        didSet {
            elevenLabsService.vadThreshold = vadThreshold
            print("🎚️ [VAD] 閾值調整: \(vadThreshold)")
        }
    }

    // MARK: - 音頻加速設定

    /// ⭐️ 音頻加速器（250ms 緩衝，2x 加速，節省 50% STT 成本）
    private let audioTimeStretcher = AudioTimeStretcher()

    /// ⭐️ 是否啟用音頻加速（2x 速度，250ms 額外延遲）
    /// 注意：Apple STT 免費，不需要加速
    var isAudioSpeedUpEnabled: Bool = false {
        didSet {
            audioTimeStretcher.setEnabled(isAudioSpeedUpEnabled)
            if isAudioSpeedUpEnabled {
                print("🚀 [STT] 音頻加速已啟用（2x，節省 50% 成本，+250ms 延遲）")
            } else {
                print("⏸️ [STT] 音頻加速已禁用")
            }
        }
    }

    /// 是否顯示音頻加速選項（Apple STT 免費不需要）
    var shouldShowSpeedUpOption: Bool {
        sttProvider != .apple
    }

    /// ⭐️ 麥克風增益（1.0 ~ 4.0）
    /// 放大送入 ElevenLabs 的音頻，讓細微聲音更容易被偵測
    var microphoneGain: Float {
        get { audioManager.microphoneGain }
        set { audioManager.microphoneGain = newValue }
    }

    /// ⭐️ 最小語音長度（毫秒）
    var minSpeechDurationMs: Int = 100 {
        didSet {
            elevenLabsService.minSpeechDurationMs = minSpeechDurationMs
            print("🎚️ [VAD] 最小語音長度: \(minSpeechDurationMs)ms")
        }
    }

    /// ⭐️ 即時麥克風音量（0.0 ~ 1.0）
    /// 注意：此變數更新頻繁，僅在設定頁面顯示時啟用更新
    var currentMicVolume: Float = 0.0

    /// ⭐️ 是否啟用音量監測更新（設定頁面開啟時才啟用）
    var isVolumeMonitoringEnabled: Bool = false

    // MARK: - Private Properties

    /// ⭐️ 三種 STT 服務
    private let chirp3Service = WebSocketService()
    private let elevenLabsService = ElevenLabsSTTService()
    private let appleSTTService = AppleSTTService()

    /// 當前使用的 STT 服務
    private var currentSTTService: WebSocketServiceProtocol {
        switch sttProvider {
        case .chirp3: return chirp3Service
        case .elevenLabs: return elevenLabsService
        case .apple: return appleSTTService
        }
    }

    /// ⭐️ 使用 WebRTC AEC3 音頻管理器（全雙工回音消除）
    private let audioManager = WebRTCAudioManager.shared

    /// ⭐️ Session 服務（對話記錄儲存到 Firestore）
    private let sessionService = SessionService.shared

    /// TTS 服務（Azure）
    private let ttsService = AzureTTSService()

    /// ⭐️ TTS 服務（Apple 內建）
    private let appleTTSService = AppleTTSService()

    /// TTS 播放隊列
    private var ttsQueue: [(text: String, lang: String)] = []
    private var isProcessingTTS = false
    /// ⭐️ 當前正在合成的文本（用於去重）
    private var currentSynthesizingText: String?

    // MARK: - Streaming TTS 系統
    // ⭐️ 支援 interim 翻譯時就開始播放，避免等待 final

    /// Streaming TTS 狀態追蹤
    /// 記錄當前 utterance 已播放到哪個位置
    private var streamingTTSState = StreamingTTSState()

    /// Streaming TTS 配置
    private struct StreamingTTSConfig {
        /// 最小分段長度（字符數）- 太短的片段不值得單獨播放
        static let minSegmentLength = 3
        /// ⭐️ interim 穩定等待時間（秒）- 收到 interim 後等待這麼久才開始播放
        /// 如果在這段時間內收到新的 interim，會重新計時
        static let interimStabilityDelay: TimeInterval = 1.0
        /// 分句標點符號
        static let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?", "，", ",", "；", ";"]
    }

    /// Streaming TTS 狀態
    private struct StreamingTTSState {
        /// 當前 utterance 的 ID（用來識別是否為同一句話）
        var currentUtteranceId: String = ""
        /// 已播放的翻譯內容（完整的已播放文本）
        var playedTranslation: String = ""
        /// 上一次的原文（用於檢測修正）
        var lastSourceText: String = ""
        /// 上一次更新時間
        var lastUpdateTime: Date = .distantPast
        /// 是否已經完成這個 utterance 的播放
        var isCompleted: Bool = false
        /// 待播放的隊列（分段）
        var pendingSegments: [String] = []
        /// ⭐️ 等待穩定的翻譯內容（等待 1 秒穩定後播放）
        var pendingTranslation: String = ""
        /// ⭐️ 等待穩定的語言代碼
        var pendingLanguageCode: String = ""

        mutating func reset() {
            currentUtteranceId = ""
            playedTranslation = ""
            lastSourceText = ""
            lastUpdateTime = .distantPast
            isCompleted = false
            pendingSegments = []
            pendingTranslation = ""
            pendingLanguageCode = ""
        }

        /// 檢測是否為新的 utterance（原文完全不同或不是前綴關係）
        mutating func isNewUtterance(sourceText: String) -> Bool {
            // 如果是第一次，視為新 utterance
            if lastSourceText.isEmpty {
                return true
            }

            // 如果新原文是舊原文的延續（前綴關係），不是新 utterance
            if sourceText.hasPrefix(lastSourceText) {
                return false
            }

            // 如果舊原文是新原文的前綴（可能是 ElevenLabs 修正），也不是新 utterance
            if lastSourceText.hasPrefix(sourceText) {
                return false
            }

            // 否則是新 utterance
            return true
        }

        /// 檢測原文是否被修正（前面的字改變了）
        func isSourceCorrected(sourceText: String) -> Bool {
            guard !lastSourceText.isEmpty else { return false }

            // 如果新原文是舊原文的延續，沒有修正
            if sourceText.hasPrefix(lastSourceText) {
                return false
            }

            // 如果舊原文是新原文的前綴，也沒有修正（只是截斷）
            if lastSourceText.hasPrefix(sourceText) {
                return false
            }

            // 其他情況都視為修正
            return true
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?
    private var startTime: Date?

    /// ⭐️ Streaming TTS 穩定計時器
    /// 收到 interim 後等待 1 秒，如果沒有新的更新才開始播放
    private var streamingTTSTimer: Timer?

    // MARK: - Initialization

    init() {
        setupSubscriptions()
        // ⭐️ 不在 init 中預取 token，避免 ViewModel 多次初始化導致重複預取
        // 改為在 ContentView 的 onAppear 中手動調用
    }

    /// ⭐️ 預取 ElevenLabs token（在 App 出現時調用一次）
    func prefetchElevenLabsToken() {
        elevenLabsService.prefetchToken(serverURL: serverURL)
    }

    // MARK: - Public Methods

    /// 是否正在處理連接/斷開
    private var isProcessing = false

    /// ⭐️ 開始通話（同步方法，立即更新 UI）
    @MainActor
    func beginCall() {
        guard !isProcessing else {
            print("⚠️ 正在處理中，忽略重複觸發")
            return
        }
        // 立即設置狀態，UI 會立即切換
        status = .connecting
    }

    /// ⭐️ 結束通話（同步方法，立即更新 UI）
    @MainActor
    func endCall() {
        // 立即設置狀態，UI 會立即切換
        status = .disconnected
        // 在背景執行清理
        Task.detached { [weak self] in
            await self?.performStopRecording()
        }
    }

    /// ⭐️ 執行連接（在背景調用）
    func performStartRecording() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        await startRecording()
    }

    /// ⭐️ 執行斷開（在背景調用）
    @MainActor
    private func performStopRecording() {
        stopRecording()
    }

    /// 切換錄音狀態（保留兼容性）
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
        // ⭐️ 立即設置連接狀態，讓 UI 先切換（順暢體驗）
        status = .connecting

        // ⭐️ 讓出主線程，讓 UI 有機會更新
        await Task.yield()

        // ⭐️ 檢查用戶額度（至少需要 100 額度才能開始）
        guard AuthService.shared.hasEnoughCredits(100) else {
            status = .error("額度不足，請購買額度")
            return
        }

        // 請求麥克風權限
        let granted = await audioManager.requestPermission()
        guard granted else {
            status = .error("請允許使用麥克風")
            return
        }

        print("🔌 開始連接伺服器: \(serverURL) (使用 \(sttProvider.displayName))")

        // ⭐️ 根據選擇的 STT 提供商連接
        currentSTTService.connect(
            serverURL: serverURL,
            sourceLang: sourceLang,
            targetLang: targetLang
        )

        // 等待連接成功（ElevenLabs 需要較長時間：token + WebSocket）
        let timeout: TimeInterval = (sttProvider == .elevenLabs) ? 20.0 : 10.0
        print("⏳ 等待連接...（超時: \(Int(timeout))秒）")
        let connectionResult = await waitForConnection(timeout: timeout)
        print("📡 連接結果: \(connectionResult), 狀態: \(currentSTTService.connectionState)")

        guard connectionResult else {
            if case .error(let message) = currentSTTService.connectionState {
                print("❌ 連接錯誤: \(message)")
                status = .error(message)
            } else {
                print("❌ 連接逾時")
                status = .error("連接逾時，請檢查網路或伺服器狀態")
            }
            currentSTTService.disconnect()
            return
        }

        print("✅ WebSocket 連接成功")

        // ⭐️ 使用統一的 AudioManager 開始錄音（內建回音消除）
        do {
            // 設置擴音模式
            audioManager.isSpeakerMode = isSpeakerMode

            try audioManager.startRecording()

            print("🔊 [WebRTC AEC3] 全雙工模式啟動（獨立錄音 + 播放引擎，AEC3 回音消除）")

            status = .recording
            startDurationTimer()

            // ⭐️ 無論是否登入，都啟動計費會話（確保 usage 被記錄）
            BillingService.shared.startSession()

            // ⭐️ VAD 模式：先開始發送音頻，這會觸發 BillingService.startAudioSending()
            // 這樣 startSTTTimer() 會知道要立即開始計費
            if inputMode == .vad {
                audioManager.startSending()
                print("🎙️ [ViewModel] VAD 模式：自動開始持續監聽")
            }

            // ⭐️ Apple STT 是免費的，不需要計費
            if sttProvider != .apple {
                BillingService.shared.startSTTTimer()
            } else {
                print("💰 [ViewModel] Apple STT 免費，不計費")
            }

            // ⭐️ 只有登入用戶才創建 Firebase Session 記錄
            if let uid = AuthService.shared.currentUser?.uid {
                Task {
                    do {
                        let sessionId = try await sessionService.createSession(
                            uid: uid,
                            sourceLang: sourceLang.rawValue,
                            targetLang: targetLang.rawValue,
                            provider: sttProvider.rawValue
                        )
                        print("✅ [ViewModel] 創建 Session: \(sessionId)")
                    } catch {
                        print("⚠️ [ViewModel] 創建 Session 失敗: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            status = .error(error.localizedDescription)
            currentSTTService.disconnect()
        }
    }

    /// 停止錄音
    @MainActor
    private func stopRecording() {
        // ⭐️ 立即設置狀態，讓 UI 先切換（順暢體驗）
        status = .disconnected

        stopDurationTimer()

        // ⭐️ 停止 STT 計時
        BillingService.shared.stopSTTTimer()

        // ⭐️ 使用統一的 AudioManager
        audioManager.stopRecording()
        audioManager.stopTTS()

        // 🚀 Flush 音頻加速器剩餘的緩衝音頻
        if isAudioSpeedUpEnabled, let remainingData = audioTimeStretcher.flush() {
            currentSTTService.sendAudio(data: remainingData)
            audioTimeStretcher.printStats()  // 打印統計信息
        }
        audioTimeStretcher.reset()

        // ⭐️ 斷開當前 STT 服務
        currentSTTService.disconnect()

        // 清除 interim 和 TTS 隊列
        interimTranscript = nil
        ttsQueue.removeAll()
        isProcessingTTS = false

        // ⭐️ 重置 Streaming TTS 狀態
        resetStreamingTTSState()

        // ⭐️ 結束 Session（保存對話記錄）
        // 注意：扣款已改為即時扣款（在 BillingService 中處理），這裡不再扣款
        Task {
            // 結束 Session 並獲取用量統計（僅用於記錄）
            let usage = await sessionService.endSession()
            print("✅ [ViewModel] 結束 Session")

            // ⭐️ 即時扣款模式：不在這裡扣款，僅記錄總用量
            if let usage = usage {
                print("💰 [ViewModel] 本次會話總用量:")
                print("   STT: \(String(format: "%.2f", usage.sttDurationSeconds))秒")
                print("   LLM: \(usage.llmInputTokens)+\(usage.llmOutputTokens) tokens")
                print("   TTS: \(usage.ttsCharCount) chars")
                print("   總額度: \(usage.totalCreditsUsed)")
            }
        }
    }

    /// 切換擴音模式
    func toggleSpeakerMode() {
        isSpeakerMode.toggle()
        // AudioManager 會通過 didSet 自動同步
        print("🔊 [ViewModel] 擴音模式: \(isSpeakerMode ? "開啟" : "關閉")")
    }

    // MARK: - Voice Isolation

    /// 顯示系統麥克風模式選擇器（Voice Isolation、Wide Spectrum、Standard）
    /// 需要在錄音中調用
    func showMicrophoneModeSelector() {
        guard isRecording else {
            print("⚠️ [ViewModel] 請先開始錄音再設定麥克風模式")
            return
        }
        audioManager.showMicrophoneModeSelector()
    }

    /// 獲取當前麥克風模式的顯示名稱
    var currentMicrophoneModeDisplayName: String {
        switch audioManager.activeMicrophoneMode {
        case .standard:
            return "標準"
        case .wideSpectrum:
            return "寬頻譜"
        case .voiceIsolation:
            return "人聲隔離"
        @unknown default:
            return "未知"
        }
    }

    // MARK: - Input Mode Methods

    /// 切換輸入模式
    func toggleInputMode() {
        inputMode = (inputMode == .ptt) ? .vad : .ptt
    }

    /// 處理輸入模式變更
    private func handleInputModeChange() {
        print("🎙️ [ViewModel] 輸入模式切換: \(inputMode.rawValue)")

        if inputMode == .vad {
            // VAD 模式：持續發送音頻
            if isRecording {
                audioManager.startSending()
            }
        } else {
            // PTT 模式：停止發送，等待按住
            audioManager.stopSending()
        }
    }

    // MARK: - Push-to-Talk Methods

    /// 開始說話（按下按鈕時調用，僅 PTT 模式有效）
    func startTalking() {
        guard isRecording else { return }
        guard inputMode == .ptt else { return }  // VAD 模式不需要手動控制
        audioManager.startSending()
    }

    /// 停止說話（放開按鈕時調用，僅 PTT 模式有效）
    func stopTalking() {
        guard inputMode == .ptt else { return }  // VAD 模式不需要手動控制
        audioManager.stopSending()
    }

    /// 設定 Combine 訂閱
    private func setupSubscriptions() {
        // ⭐️ 訂閱音頻數據（來自統一的 AudioManager）
        // 根據當前選擇的 STT 提供商發送到對應服務
        // 🚀 如果啟用加速，先通過 AudioTimeStretcher 處理
        audioManager.audioDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self else { return }

                // 🚀 音頻加速處理
                if self.isAudioSpeedUpEnabled && self.sttProvider != .apple {
                    // 通過加速器處理（250ms 緩衝 → 125ms 輸出）
                    if let processedData = self.audioTimeStretcher.process(data: data) {
                        self.currentSTTService.sendAudio(data: processedData)
                    }
                    // 如果返回 nil，表示還在緩衝中，等待下一塊
                } else {
                    // 不加速，直接發送原始音頻
                    self.currentSTTService.sendAudio(data: data)
                }
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱 Chirp3 服務的結果
        chirp3Service.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard self?.sttProvider == .chirp3 else { return }
                self?.handleTranscript(transcript)
            }
            .store(in: &cancellables)

        chirp3Service.translationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sourceText, translatedText) in
                guard self?.sttProvider == .chirp3 else { return }
                self?.handleTranslation(sourceText: sourceText, translatedText: translatedText)
            }
            .store(in: &cancellables)

        chirp3Service.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                guard self?.sttProvider == .chirp3 else { return }
                self?.status = .error(errorMessage)
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱 ElevenLabs 服務的結果
        elevenLabsService.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard self?.sttProvider == .elevenLabs else { return }
                self?.handleTranscript(transcript)
            }
            .store(in: &cancellables)

        elevenLabsService.translationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sourceText, translatedText) in
                guard self?.sttProvider == .elevenLabs else { return }
                self?.handleTranslation(sourceText: sourceText, translatedText: translatedText)
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱 ElevenLabs 分句翻譯結果
        elevenLabsService.segmentedTranslationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sourceText, segments) in
                guard self?.sttProvider == .elevenLabs else { return }
                self?.handleSegmentedTranslation(sourceText: sourceText, segments: segments)
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱 ElevenLabs 修正事件（替換上一句 Final）
        elevenLabsService.correctionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (oldText, newText) in
                guard self?.sttProvider == .elevenLabs else { return }
                self?.handleCorrection(oldText: oldText, newText: newText)
            }
            .store(in: &cancellables)

        elevenLabsService.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                guard self?.sttProvider == .elevenLabs else { return }
                self?.status = .error(errorMessage)
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱 Apple STT 服務的結果
        appleSTTService.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard self?.sttProvider == .apple else { return }
                self?.handleTranscript(transcript)
            }
            .store(in: &cancellables)

        appleSTTService.translationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sourceText, translatedText) in
                guard self?.sttProvider == .apple else { return }
                self?.handleTranslation(sourceText: sourceText, translatedText: translatedText)
            }
            .store(in: &cancellables)

        appleSTTService.segmentedTranslationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sourceText, segments) in
                guard self?.sttProvider == .apple else { return }
                self?.handleSegmentedTranslation(sourceText: sourceText, segments: segments)
            }
            .store(in: &cancellables)

        appleSTTService.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                guard self?.sttProvider == .apple else { return }
                self?.status = .error(errorMessage)
            }
            .store(in: &cancellables)

        // ⭐️ TTS 播放完成回調（播放隊列中的下一個）
        audioManager.onTTSPlaybackFinished = { [weak self] in
            self?.processNextTTS()
        }

        // ⭐️ Apple TTS 播放完成回調
        appleTTSService.onPlaybackFinished = { [weak self] in
            self?.processNextTTS()
        }

        // ⭐️ PTT 結束語句回調（發送結束信號）
        audioManager.onEndUtterance = { [weak self] in
            self?.currentSTTService.sendEndUtterance()
        }

        // ⭐️ 訂閱即時麥克風音量（節流：只在設定頁面開啟時更新）
        audioManager.volumePublisher
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)  // 節流：最多每 100ms 更新一次
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                guard let self = self else { return }
                // ⭐️ 只在設定頁面開啟時才更新 UI 變數，避免不必要的重繪
                if self.isVolumeMonitoringEnabled {
                    self.currentMicVolume = volume
                }
            }
            .store(in: &cancellables)
    }

    /// 切換 STT 提供商（三選一循環）
    func toggleSTTProvider() {
        switch sttProvider {
        case .chirp3:
            sttProvider = .elevenLabs
        case .elevenLabs:
            sttProvider = .apple
        case .apple:
            sttProvider = .chirp3
        }
    }

    /// 處理轉錄結果
    private func handleTranscript(_ transcript: TranscriptMessage) {
        if transcript.isFinal {
            // 最終結果：添加到列表末尾（最新的在下面）
            var finalTranscript = transcript

            // ⭐️ 檢查新句子是否「包含」上一句（ElevenLabs 延續問題）
            // 例如：上一句 "我都沒懂解說"，新句子 "我都沒懂解說，你們就算吧"
            // 這種情況下應該刪除上一句，只保留新的完整句子
            if let lastTranscript = transcripts.last {
                let newText = transcript.text
                let lastText = lastTranscript.text

                // 檢查新句子是否以上一句為前綴
                if newText.hasPrefix(lastText) && newText.count > lastText.count {
                    // 新句子包含上一句，刪除上一句
                    print("🔄 [合併] 新句子包含上一句，刪除舊句子")
                    print("   舊: \"\(lastText.prefix(30))...\"")
                    print("   新: \"\(newText.prefix(40))...\"")
                    transcripts.removeLast()
                }
                // 也檢查是否有高度重疊（上一句是新句子的前綴，且重疊 >= 70%）
                else if lastText.count >= 5 {
                    // 找出最長的共同前綴
                    var commonPrefixLength = 0
                    let newChars = Array(newText)
                    let lastChars = Array(lastText)
                    for i in 0..<min(newChars.count, lastChars.count) {
                        if newChars[i] == lastChars[i] {
                            commonPrefixLength += 1
                        } else {
                            break
                        }
                    }

                    // 如果共同前綴佔上一句的 70% 以上，視為重複
                    let overlapRatio = Float(commonPrefixLength) / Float(lastText.count)
                    if overlapRatio >= 0.7 && commonPrefixLength >= 5 {
                        print("🔄 [合併] 新句子與上一句高度重疊 (\(Int(overlapRatio * 100))%)，刪除舊句子")
                        print("   舊: \"\(lastText.prefix(30))...\"")
                        print("   新: \"\(newText.prefix(40))...\"")
                        transcripts.removeLast()
                    }
                }
            }

            // ⭐️ Chirp3 模式：保留 interim 的翻譯（定時翻譯的結果）
            // ⭐️ ElevenLabs 模式：不保留，讓 service 層決定是否重新翻譯完整句子
            //    ElevenLabs 在 VAD commit 時會判斷翻譯是否完整，不完整則重新翻譯
            if sttProvider == .chirp3 {
                if let interimTranslation = interimTranscript?.translation, !interimTranslation.isEmpty {
                    finalTranscript.translation = interimTranslation
                    print("✅ [Final/Chirp3] 保留 interim 翻譯: \"\(interimTranslation.prefix(30))...\"")

                    // ⭐️ 從 interim 保留翻譯時，觸發 TTS 播放
                    let detectedLanguage = interimTranscript?.language
                    if shouldPlayTTSForMode(detectedLanguage: detectedLanguage) {
                        let targetLangCode = getTargetLanguageCode(detectedLanguage: detectedLanguage)
                        enqueueTTS(text: interimTranslation, languageCode: targetLangCode)
                    }
                }
            }
            // ElevenLabs 模式：等待 service 層發送完整翻譯
            // 不在這裡保留 interim 翻譯，避免不完整翻譯覆蓋後續的完整翻譯

            transcripts.append(finalTranscript)
            interimTranscript = nil
            updateStats()

            // ⭐️ 保存對話到 Session（判斷是否為來源語言）
            let isSource = isSourceLanguage(detectedLanguage: finalTranscript.language)
            sessionService.addConversation(finalTranscript, isSource: isSource)
        } else {
            // ⭐️ 中間結果：檢查是否為新的語句
            // 注意：ElevenLabs 使用 VAD 自動 commit，不需要 Pseudo-Final 機制
            // Chirp3 可能需要，因為有時 final 結果會丟失

            // 只對 Chirp3 啟用 Pseudo-Final（ElevenLabs VAD 會自動處理）
            if sttProvider == .chirp3, let oldInterim = interimTranscript {
                let oldText = oldInterim.text.replacingOccurrences(of: " ", with: "")
                let newText = transcript.text.replacingOccurrences(of: " ", with: "")

                // 判斷是否為新語句：新文本不以舊文本為前綴，且舊文本長度 > 10
                let isNewUtterance = !newText.hasPrefix(oldText) && oldText.count > 10

                if isNewUtterance {
                    // 將舊的 interim 提升為 pseudo-final（避免丟失）
                    print("⚠️ [Pseudo-Final] 檢測到新語句，保存舊 interim: \"\(oldInterim.text.prefix(30))...\"")
                    let pseudoFinal = TranscriptMessage(
                        text: oldInterim.text,
                        isFinal: true,  // 標記為 final
                        confidence: oldInterim.confidence,
                        language: oldInterim.language,
                        converted: oldInterim.converted,
                        originalText: oldInterim.originalText,
                        speakerTag: oldInterim.speakerTag
                    )
                    transcripts.append(pseudoFinal)
                    updateStats()

                    // ⭐️ 保存 Pseudo-Final 到 Session
                    let isSource = isSourceLanguage(detectedLanguage: pseudoFinal.language)
                    sessionService.addConversation(pseudoFinal, isSource: isSource)
                }
            }

            // ⭐️ 更新 interim，但保留舊的翻譯（避免翻譯閃現後消失）
            let oldTranslation = interimTranscript?.translation
            interimTranscript = transcript
            if let translation = oldTranslation, !translation.isEmpty {
                interimTranscript?.translation = translation
            }
        }
    }

    /// 處理翻譯結果
    /// ⭐️ 關鍵改進：防止跨語言錯配
    /// 問題：當用戶說了兩句不同語言（如先中文後英文），
    ///       翻譯結果（英文）可能會錯配到第二句（也是英文）
    /// 解決：模糊匹配時檢查語言是否一致，只匹配同語言的 transcript
    private func handleTranslation(sourceText: String, translatedText: String) {
        // 找到對應的轉錄並添加翻譯
        var detectedLanguage: String? = nil

        // ⭐️ DEBUG: 打印匹配信息
        print("🔍 [翻譯匹配] sourceText: \"\(sourceText.prefix(50))\"")
        print("🔍 [翻譯匹配] translatedText: \"\(translatedText.prefix(50))\"")
        print("🔍 [翻譯匹配] transcripts 數量: \(transcripts.count)")

        // ⭐️ 檢測 sourceText 的語言（用於防止跨語言錯配）
        let sourceTextLang = detectLanguageFromText(sourceText)
        print("🔍 [翻譯匹配] sourceText 語言: \(sourceTextLang)")

        // ⭐️ 先嘗試精確匹配（最可靠）
        if let index = transcripts.firstIndex(where: { $0.text == sourceText }) {
            // 精確匹配到 final 結果
            detectedLanguage = transcripts[index].language
            transcripts[index].translation = translatedText
            print("✅ [翻譯匹配] 精確匹配到 transcripts[\(index)]")
        }
        // ⭐️ 再嘗試模糊匹配（前綴匹配，處理標點差異）
        // ⭐️ 改進：只匹配語言相同的 transcript，防止跨語言錯配
        else if let index = transcripts.firstIndex(where: { transcript in
            let textMatch = transcript.text.hasPrefix(sourceText) || sourceText.hasPrefix(transcript.text)
            guard textMatch else { return false }

            // ⭐️ 語言檢查：防止跨語言錯配
            // 如果 transcript 有語言標記，確保與 sourceText 語言一致
            if let transcriptLang = transcript.language {
                let transcriptLangBase = transcriptLang.split(separator: "-").first.map(String.init) ?? transcriptLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                if transcriptLangBase != sourceTextLangBase {
                    print("⚠️ [翻譯匹配] 語言不匹配，跳過: transcript=\(transcriptLangBase), source=\(sourceTextLangBase)")
                    return false
                }
            }
            return true
        }) {
            detectedLanguage = transcripts[index].language
            transcripts[index].translation = translatedText
            print("✅ [翻譯匹配] 模糊匹配到 transcripts[\(index)]（語言一致）")
        }
        // ⭐️ 只有當 sourceText 和 interimTranscript 匹配時才更新 interim
        // ⭐️ 同樣加入語言檢查
        else if let interim = interimTranscript {
            let textMatch = interim.text == sourceText ||
                           interim.text.hasPrefix(sourceText) ||
                           sourceText.hasPrefix(interim.text)

            // ⭐️ 語言檢查
            var langMatch = true
            if let interimLang = interim.language {
                let interimLangBase = interimLang.split(separator: "-").first.map(String.init) ?? interimLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                langMatch = interimLangBase == sourceTextLangBase
            }

            if textMatch && langMatch {
                interimTranscript?.translation = translatedText
                detectedLanguage = interim.language
                print("🔄 [翻譯] 更新 interim 翻譯: \"\(translatedText.prefix(30))...\"")
            } else if textMatch && !langMatch {
                print("⚠️ [翻譯匹配] interim 語言不匹配，丟棄")
                print("   interim 語言: \(interim.language ?? "nil")")
                print("   sourceText 語言: \(sourceTextLang)")
                return
            } else {
                print("⚠️ [翻譯匹配] 無法匹配，丟棄翻譯")
                print("   sourceText: \(sourceText.prefix(30))...")
                print("   interimText: \(interim.text.prefix(30))...")
                return
            }
        }
        // ⭐️ 完全不匹配，丟棄這個翻譯（可能是舊的 async 回調）
        else {
            print("⚠️ [翻譯匹配] 無法匹配，丟棄翻譯（無 interim）")
            print("   sourceText: \(sourceText.prefix(30))...")
            return  // ⭐️ 直接返回，不播放 TTS
        }

        // ⭐️ 只在 Final 時播放 TTS（不使用 Streaming TTS）
        // 判斷是否為 final（匹配到 transcripts 陣列中的 = final，匹配到 interimTranscript = interim）
        let isFinal = interimTranscript?.text != sourceText

        // 只有 final 才播放 TTS
        if isFinal {
            // 檢查 TTS 播放模式
            guard shouldPlayTTSForMode(detectedLanguage: detectedLanguage) else {
                return
            }

            // 判斷翻譯的目標語言
            let targetLangCode = getTargetLanguageCode(detectedLanguage: detectedLanguage)

            // 加入 TTS 播放隊列
            enqueueTTS(text: translatedText, languageCode: targetLangCode)
            print("🎵 [TTS] Final 播放: \"\(translatedText.prefix(30))...\"")
        }
    }

    /// ⭐️ 處理 ElevenLabs 修正事件
    /// 當 ElevenLabs 修正之前的識別結果時，替換上一句 Final
    /// - Parameters:
    ///   - oldText: 被修正的舊文本（上一句 Final）
    ///   - newText: 修正後的新文本（當前 interim）
    private func handleCorrection(oldText: String, newText: String) {
        print("🔄 [修正] 收到修正事件")
        print("   舊: \"\(oldText.prefix(40))...\"")
        print("   新: \"\(newText.prefix(40))...\"")

        // 找到並移除上一句 Final
        if let index = transcripts.lastIndex(where: { $0.text == oldText }) {
            let removedTranscript = transcripts.remove(at: index)
            print("   ✅ 已移除 transcripts[\(index)]: \"\(removedTranscript.text.prefix(30))...\"")

            // 更新統計
            updateStats()
        } else {
            // 嘗試模糊匹配（可能有輕微差異）
            if let index = transcripts.lastIndex(where: { transcript in
                // 檢查是否有共同前綴
                let minLength = min(transcript.text.count, oldText.count)
                guard minLength >= 4 else { return false }
                let transcriptPrefix = String(transcript.text.prefix(minLength / 2))
                let oldTextPrefix = String(oldText.prefix(minLength / 2))
                return transcriptPrefix == oldTextPrefix
            }) {
                let removedTranscript = transcripts.remove(at: index)
                print("   ✅ 模糊匹配並移除 transcripts[\(index)]: \"\(removedTranscript.text.prefix(30))...\"")
                updateStats()
            } else {
                print("   ⚠️ 未找到匹配的 transcript，可能已被處理")
            }
        }
    }

    /// ⭐️ 處理分句翻譯結果
    /// 當後端返回多段分句翻譯時，將分句存入對應的 transcript
    private func handleSegmentedTranslation(sourceText: String, segments: [TranslationSegment]) {
        guard !segments.isEmpty else { return }

        print("✂️ [分句翻譯匹配] sourceText: \"\(sourceText.prefix(40))...\"")
        print("   segments: \(segments.count) 段")

        // 檢測 sourceText 的語言（用於防止跨語言錯配）
        let sourceTextLang = detectLanguageFromText(sourceText)
        var shouldPlayTTS = false
        var detectedLanguage: String? = nil

        // ⭐️ 先嘗試精確匹配 transcripts
        if let index = transcripts.firstIndex(where: { $0.text == sourceText }) {
            let existingTranslation = transcripts[index].translation
            if existingTranslation == nil || existingTranslation?.isEmpty == true {
                shouldPlayTTS = true
            }
            detectedLanguage = transcripts[index].language
            transcripts[index].translationSegments = segments
            transcripts[index].translation = segments.map { $0.translation }.joined(separator: " ")
            print("✅ [分句翻譯] 精確匹配到 transcripts[\(index)]，\(segments.count) 段")
        }
        // ⭐️ 模糊匹配（前綴匹配，且語言一致）
        else if let index = transcripts.firstIndex(where: { transcript in
            let textMatch = transcript.text.hasPrefix(sourceText) || sourceText.hasPrefix(transcript.text)
            guard textMatch else { return false }

            // 語言檢查
            if let transcriptLang = transcript.language {
                let transcriptLangBase = transcriptLang.split(separator: "-").first.map(String.init) ?? transcriptLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                if transcriptLangBase != sourceTextLangBase {
                    return false
                }
            }
            return true
        }) {
            let existingTranslation = transcripts[index].translation
            if existingTranslation == nil || existingTranslation?.isEmpty == true {
                shouldPlayTTS = true
            }
            detectedLanguage = transcripts[index].language
            transcripts[index].translationSegments = segments
            transcripts[index].translation = segments.map { $0.translation }.joined(separator: " ")
            print("✅ [分句翻譯] 模糊匹配到 transcripts[\(index)]，\(segments.count) 段")
        }
        // ⭐️ 匹配 interimTranscript
        else if let interim = interimTranscript {
            let textMatch = interim.text == sourceText ||
                           interim.text.hasPrefix(sourceText) ||
                           sourceText.hasPrefix(interim.text)

            var langMatch = true
            if let interimLang = interim.language {
                let interimLangBase = interimLang.split(separator: "-").first.map(String.init) ?? interimLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                langMatch = interimLangBase == sourceTextLangBase
            }

            if textMatch && langMatch {
                interimTranscript?.translationSegments = segments
                interimTranscript?.translation = segments.map { $0.translation }.joined(separator: " ")
                detectedLanguage = interim.language
                print("🔄 [分句翻譯] 更新 interim，\(segments.count) 段")
            } else {
                print("⚠️ [分句翻譯] 無法匹配 interim，丟棄")
                return
            }
        } else {
            print("⚠️ [分句翻譯] 無法匹配任何 transcript，丟棄")
            return
        }

        // ⭐️ 根據 TTS 播放模式決定是否播放
        if shouldPlayTTS {
            shouldPlayTTS = shouldPlayTTSForMode(detectedLanguage: detectedLanguage)
        }

        if shouldPlayTTS {
            // 播放合併後的翻譯
            let fullTranslation = segments.map { $0.translation }.joined(separator: " ")
            let targetLangCode = getTargetLanguageCode(detectedLanguage: detectedLanguage)
            enqueueTTS(text: fullTranslation, languageCode: targetLangCode)
        }
    }

    /// ⭐️ 簡單的語言檢測（用於防止跨語言錯配）
    /// 根據文本中的字符類型判斷主要語言
    private func detectLanguageFromText(_ text: String) -> String {
        var chineseCount = 0
        var japaneseCount = 0
        var koreanCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0x4E00 && value <= 0x9FFF {
                // CJK 統一漢字
                chineseCount += 1
            } else if (value >= 0x3040 && value <= 0x309F) || (value >= 0x30A0 && value <= 0x30FF) {
                // 平假名 + 片假名
                japaneseCount += 1
            } else if value >= 0xAC00 && value <= 0xD7AF {
                // 韓文音節
                koreanCount += 1
            } else if (value >= 0x0041 && value <= 0x005A) || (value >= 0x0061 && value <= 0x007A) {
                // 拉丁字母 (A-Z, a-z)
                latinCount += 1
            }
        }

        // 如果有日文假名，優先判斷為日文
        if japaneseCount > 0 {
            return "ja"
        }
        // 如果有韓文，判斷為韓文
        if koreanCount > 0 {
            return "ko"
        }
        // 中文字多於拉丁字，判斷為中文
        if chineseCount > latinCount {
            return "zh"
        }
        // 預設為英文
        return "en"
    }

    /// 根據 TTS 播放模式判斷是否應該播放
    /// - Parameter detectedLanguage: Chirp3 檢測到的語言代碼
    /// - Returns: 是否應該播放 TTS
    private func shouldPlayTTSForMode(detectedLanguage: String?) -> Bool {
        switch ttsPlaybackMode {
        case .muted:
            return false
        case .all:
            return true
        case .sourceOnly:
            // 只有當原文是「來源語言」時才播放翻譯結果
            // 例如：用戶設定 sourceLang=zh, targetLang=en
            // 當用戶說中文（來源語言）→ 播放英文翻譯
            guard let detected = detectedLanguage else { return false }
            let detectedBase = detected.split(separator: "-").first.map(String.init) ?? detected
            return detectedBase == sourceLang.rawValue
        case .targetOnly:
            // 只有當原文是「目標語言」時才播放翻譯結果
            // 例如：用戶設定 sourceLang=zh, targetLang=en
            // 當對方說英文（目標語言）→ 播放中文翻譯
            guard let detected = detectedLanguage else { return false }
            let detectedBase = detected.split(separator: "-").first.map(String.init) ?? detected
            return detectedBase == targetLang.rawValue
        }
    }

    // MARK: - TTS Methods

    /// 獲取翻譯結果的目標語言 Azure locale 代碼
    /// - Parameters:
    ///   - detectedLanguage: STT 檢測到的原文語言（如 "zh", "en", "ja" 等）
    /// - Returns: Azure TTS locale 代碼（如 "zh-TW", "en-US", "ja-JP" 等）
    ///
    /// 邏輯說明：
    /// - 如果原文是「來源語言」→ 翻譯到「目標語言」→ TTS 播放目標語言
    /// - 如果原文是「目標語言」→ 翻譯到「來源語言」→ TTS 播放來源語言
    private func getTargetLanguageCode(detectedLanguage: String?) -> String {
        guard let detected = detectedLanguage else {
            // 無法檢測，預設使用目標語言
            return targetLang.azureLocale
        }

        // 提取基礎語言代碼（如 "zh-TW" → "zh"）
        let detectedBase = detected.split(separator: "-").first.map(String.init) ?? detected

        // 判斷原文語言，決定翻譯目標
        if detectedBase == sourceLang.rawValue {
            // 原文是來源語言 → 翻譯到目標語言
            return targetLang.azureLocale
        } else if detectedBase == targetLang.rawValue {
            // 原文是目標語言 → 翻譯到來源語言
            return sourceLang.azureLocale
        } else {
            // 無法判斷，預設使用目標語言
            return targetLang.azureLocale
        }
    }

    /// ⭐️ 判斷是否為來源語言（用於 Session 記錄的 position）
    /// - Parameter detectedLanguage: STT 檢測到的語言代碼
    /// - Returns: true = 來源語言（用戶說的，position: right），false = 目標語言（對方說的，position: left）
    private func isSourceLanguage(detectedLanguage: String?) -> Bool {
        guard let detected = detectedLanguage else {
            // 無法檢測，預設為來源語言
            return true
        }

        let detectedBase = detected.split(separator: "-").first.map(String.init) ?? detected
        return detectedBase == sourceLang.rawValue
    }

    // MARK: - Streaming TTS 處理

    /// ⭐️ Streaming TTS：處理 interim 翻譯，增量播放
    /// 核心邏輯：
    /// - interim：等待 1 秒穩定後才開始播放（如果 1 秒內有新 interim 則重新計時）
    /// - final：立即播放，不等待
    /// - Parameters:
    ///   - sourceText: 原文（用於追蹤 utterance）
    ///   - translatedText: 翻譯後的完整文本
    ///   - languageCode: TTS 語言代碼
    ///   - isFinal: 是否為最終結果
    private func handleStreamingTTS(sourceText: String, translatedText: String, languageCode: String, isFinal: Bool) {
        // 檢查 TTS 播放模式
        let detectedLanguage = detectLanguageFromText(sourceText)
        guard shouldPlayTTSForMode(detectedLanguage: detectedLanguage) else {
            return
        }

        // ⭐️ 檢測是否為新的 utterance
        if streamingTTSState.isNewUtterance(sourceText: sourceText) {
            print("🆕 [Streaming TTS] 新 utterance 開始")
            print("   舊原文: \"\(streamingTTSState.lastSourceText.prefix(30))...\"")
            print("   新原文: \"\(sourceText.prefix(30))...\"")

            // 取消之前的計時器
            streamingTTSTimer?.invalidate()
            streamingTTSTimer = nil

            // 重置狀態
            streamingTTSState.reset()
            streamingTTSState.currentUtteranceId = UUID().uuidString
        }

        // ⭐️ 檢測原文是否被修正（前面的字改變了）
        if streamingTTSState.isSourceCorrected(sourceText: sourceText) {
            print("🔄 [Streaming TTS] 原文被修正，只播放新增部分")
            print("   舊原文: \"\(streamingTTSState.lastSourceText.prefix(30))...\"")
            print("   新原文: \"\(sourceText.prefix(30))...\"")
        }

        // 更新狀態
        streamingTTSState.lastSourceText = sourceText
        streamingTTSState.lastUpdateTime = Date()

        // ⭐️ 計算需要播放的新增內容
        let newContent = calculateNewTTSContent(fullTranslation: translatedText)

        if newContent.isEmpty {
            if isFinal {
                streamingTTSState.isCompleted = true
                streamingTTSTimer?.invalidate()
                streamingTTSTimer = nil
                print("✅ [Streaming TTS] utterance 完成（無新內容）")
            }
            return
        }

        // ⭐️ Final 結果：立即播放，不等待
        if isFinal {
            // 取消計時器（Final 已到達，不需要等待）
            streamingTTSTimer?.invalidate()
            streamingTTSTimer = nil

            // 立即播放
            enqueueTTS(text: newContent, languageCode: languageCode)
            streamingTTSState.playedTranslation = translatedText
            streamingTTSState.isCompleted = true
            print("🎵 [Streaming TTS] Final 立即播放: \"\(newContent.prefix(30))...\"")
            return
        }

        // ⭐️ Interim 結果：等待 1 秒穩定後才播放
        // 保存待播放的內容（每次收到新 interim 都會更新）
        streamingTTSState.pendingTranslation = translatedText
        streamingTTSState.pendingLanguageCode = languageCode

        // 取消之前的計時器（重新計時）
        streamingTTSTimer?.invalidate()

        print("⏳ [Streaming TTS] 等待穩定 (\(StreamingTTSConfig.interimStabilityDelay)秒): \"\(newContent.prefix(30))...\"")

        // 設置新的計時器：1 秒後如果沒有新的 interim 就播放
        streamingTTSTimer = Timer.scheduledTimer(withTimeInterval: StreamingTTSConfig.interimStabilityDelay, repeats: false) { [weak self] _ in
            guard let self else { return }

            // 確保在主線程執行
            DispatchQueue.main.async {
                self.playPendingStreamingTTS()
            }
        }
    }

    /// ⭐️ 播放等待中的 Streaming TTS（計時器觸發時調用）
    private func playPendingStreamingTTS() {
        let pendingTranslation = streamingTTSState.pendingTranslation
        let languageCode = streamingTTSState.pendingLanguageCode

        guard !pendingTranslation.isEmpty else {
            print("⚠️ [Streaming TTS] 計時器觸發但無待播放內容")
            return
        }

        // 計算需要播放的新增內容
        let newContent = calculateNewTTSContent(fullTranslation: pendingTranslation)

        guard !newContent.isEmpty else {
            print("⚠️ [Streaming TTS] 計時器觸發但無新增內容")
            return
        }

        // 播放
        enqueueTTS(text: newContent, languageCode: languageCode)
        streamingTTSState.playedTranslation = pendingTranslation

        print("🎵 [Streaming TTS] 穩定後播放: \"\(newContent.prefix(30))...\"")
        print("   已播放總長度: \(streamingTTSState.playedTranslation.count) 字符")
    }

    /// 計算需要播放的新增內容
    /// - Parameter fullTranslation: 完整的翻譯文本
    /// - Returns: 需要播放的新增部分
    private func calculateNewTTSContent(fullTranslation: String) -> String {
        let playedText = streamingTTSState.playedTranslation

        // 如果沒有已播放內容，返回全部
        if playedText.isEmpty {
            return fullTranslation
        }

        // ⭐️ 情況 1：新翻譯是已播放內容的延續（最常見）
        if fullTranslation.hasPrefix(playedText) {
            let newPart = String(fullTranslation.dropFirst(playedText.count))
            return newPart.trimmingCharacters(in: .whitespaces)
        }

        // ⭐️ 情況 2：已播放內容是新翻譯的前綴（翻譯被截斷，不應發生）
        if playedText.hasPrefix(fullTranslation) {
            // 新翻譯比已播放的短，不播放任何內容
            return ""
        }

        // ⭐️ 情況 3：翻譯被修正（前面的內容改變了）
        // 找出共同前綴，只播放後面的部分
        let commonPrefixLength = findCommonPrefixLength(playedText, fullTranslation)

        if commonPrefixLength > 0 {
            // 有共同前綴，播放新翻譯中超出共同前綴的部分
            // 但要考慮已播放的部分
            let newPart = String(fullTranslation.dropFirst(max(commonPrefixLength, playedText.count)))
            if !newPart.isEmpty {
                print("🔀 [Streaming TTS] 翻譯有修正，播放差異: \"\(newPart.prefix(20))...\"")
                return newPart.trimmingCharacters(in: .whitespaces)
            }
        }

        // ⭐️ 情況 4：完全不同的翻譯
        // 這不應該發生（應該是新 utterance），但為了安全起見
        print("⚠️ [Streaming TTS] 翻譯完全不同，重新開始")
        streamingTTSState.playedTranslation = ""
        return fullTranslation
    }

    /// 找出兩個字串的共同前綴長度
    private func findCommonPrefixLength(_ str1: String, _ str2: String) -> Int {
        let chars1 = Array(str1)
        let chars2 = Array(str2)
        var length = 0

        for i in 0..<min(chars1.count, chars2.count) {
            if chars1[i] == chars2[i] {
                length += 1
            } else {
                break
            }
        }

        return length
    }

    /// 重置 Streaming TTS 狀態（在停止錄音時調用）
    private func resetStreamingTTSState() {
        // 取消計時器
        streamingTTSTimer?.invalidate()
        streamingTTSTimer = nil

        streamingTTSState.reset()
        print("🔄 [Streaming TTS] 狀態已重置")
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

        // ⭐️ 根據 TTS 服務商選擇不同的播放方式
        switch ttsProvider {
        case .azure:
            // Azure TTS：網路合成 → WebRTC 播放
            Task {
                do {
                    print("🎙️ [Azure TTS] 合成中: \"\(item.text.prefix(30))...\"")

                    // 獲取音頻數據
                    let audioData = try await ttsService.synthesize(
                        text: item.text,
                        languageCode: item.lang
                    )

                    // ⭐️ 使用 AudioManager 播放（同一 Engine，AEC 啟用）
                    try audioManager.playTTS(audioData: audioData, text: item.text)

                    // 播放開始後清除合成文本（currentTTSText 已接管）
                    currentSynthesizingText = nil

                    print("▶️ [Azure TTS] 播放中（錄音繼續，回音消除啟用）")

                } catch {
                    print("❌ [Azure TTS] 錯誤: \(error.localizedDescription)")
                    currentSynthesizingText = nil  // 清除
                    // 繼續處理下一個
                    processNextTTS()
                }
            }

        case .apple:
            // ⭐️ 檢查 Apple TTS 是否支援此語言
            if AppleTTSService.isLanguageSupported(item.lang) {
                // Apple TTS：本地合成 + 直接播放（免費、離線）
                print("🎙️ [Apple TTS] 播放中: \"\(item.text.prefix(30))...\"")

                // ⭐️ Apple TTS 不計費
                // 注意：Apple TTS 直接播放，不經過 WebRTC
                // AEC 仍然有效（因為共享同一個 AudioSession）
                appleTTSService.speak(text: item.text, languageCode: item.lang)
                currentSynthesizingText = nil
            } else {
                // ⭐️ 自動降級到 Azure TTS
                print("⚠️ [Apple TTS] 不支援 \(item.lang)，自動降級到 Azure TTS")

                Task {
                    do {
                        print("🎙️ [Azure TTS 降級] 合成中: \"\(item.text.prefix(30))...\"")

                        let audioData = try await ttsService.synthesize(
                            text: item.text,
                            languageCode: item.lang
                        )

                        try audioManager.playTTS(audioData: audioData, text: item.text)
                        currentSynthesizingText = nil

                        print("▶️ [Azure TTS 降級] 播放中")

                    } catch {
                        print("❌ [Azure TTS 降級] 錯誤: \(error.localizedDescription)")
                        currentSynthesizingText = nil
                        processNextTTS()
                    }
                }
            }
        }
    }

    /// 停止當前 TTS 播放
    /// 停止所有 TTS（清空隊列）
    func stopCurrentTTS() {
        // ⭐️ 根據當前服務商停止對應的服務
        switch ttsProvider {
        case .azure:
            audioManager.stopTTS()
        case .apple:
            appleTTSService.stop()
        }
        ttsQueue.removeAll()
        isProcessingTTS = false
    }

    /// ⭐️ 停止當前 TTS 並播放下一個（不清空隊列）
    func skipCurrentTTS() {
        print("⏭️ [TTS] 跳過當前播放，播放下一個")
        // ⭐️ 根據當前服務商停止對應的服務
        switch ttsProvider {
        case .azure:
            audioManager.stopTTS()
        case .apple:
            appleTTSService.stop()
        }
        // 不清空隊列，繼續播放下一個
        processNextTTS()
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
        // ⭐️ 縮短輪詢間隔：50ms（原本 100ms）
        // 更頻繁檢查可以更快響應連接成功
        let checkInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

        while Date().timeIntervalSince(startTime) < timeout {
            // ⭐️ 檢查當前 STT 服務的連接狀態
            switch currentSTTService.connectionState {
            case .connected:
                let elapsed = Date().timeIntervalSince(startTime)
                print("⚡️ [連線] 完成（耗時 \(String(format: "%.2f", elapsed))秒）")
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
