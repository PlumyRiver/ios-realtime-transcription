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

    /// TTS 播放模式（四段切換）
    var ttsPlaybackMode: TTSPlaybackMode = .all

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
        audioManager.isPlayingTTS
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

    // MARK: - Private Properties

    /// ⭐️ 雙 STT 服務
    private let chirp3Service = WebSocketService()
    private let elevenLabsService = ElevenLabsSTTService()

    /// 當前使用的 STT 服務
    private var currentSTTService: WebSocketServiceProtocol {
        switch sttProvider {
        case .chirp3: return chirp3Service
        case .elevenLabs: return elevenLabsService
        }
    }

    /// ⭐️ 使用 WebRTC AEC3 音頻管理器（全雙工回音消除）
    private let audioManager = WebRTCAudioManager.shared

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

            // ⭐️ VAD 模式：自動開始發送音頻
            if inputMode == .vad {
                audioManager.startSending()
                print("🎙️ [ViewModel] VAD 模式：自動開始持續監聽")
            }

            status = .recording
            startDurationTimer()
        } catch {
            status = .error(error.localizedDescription)
            currentSTTService.disconnect()
        }
    }

    /// 停止錄音
    @MainActor
    private func stopRecording() {
        stopDurationTimer()

        // ⭐️ 使用統一的 AudioManager
        audioManager.stopRecording()
        audioManager.stopTTS()

        // ⭐️ 斷開當前 STT 服務
        currentSTTService.disconnect()
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
        audioManager.audioDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self else { return }
                self.currentSTTService.sendAudio(data: data)
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

        elevenLabsService.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                guard self?.sttProvider == .elevenLabs else { return }
                self?.status = .error(errorMessage)
            }
            .store(in: &cancellables)

        // ⭐️ TTS 播放完成回調（播放隊列中的下一個）
        audioManager.onTTSPlaybackFinished = { [weak self] in
            self?.processNextTTS()
        }

        // ⭐️ PTT 結束語句回調（發送結束信號）
        audioManager.onEndUtterance = { [weak self] in
            self?.currentSTTService.sendEndUtterance()
        }
    }

    /// 切換 STT 提供商
    func toggleSTTProvider() {
        sttProvider = (sttProvider == .chirp3) ? .elevenLabs : .chirp3
    }

    /// 處理轉錄結果
    private func handleTranscript(_ transcript: TranscriptMessage) {
        if transcript.isFinal {
            // 最終結果：添加到列表末尾（最新的在下面）
            var finalTranscript = transcript

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
                        let targetLangCode = getTargetLanguageCode(for: interimTranslation)
                        enqueueTTS(text: interimTranslation, languageCode: targetLangCode)
                    }
                }
            }
            // ElevenLabs 模式：等待 service 層發送完整翻譯
            // 不在這裡保留 interim 翻譯，避免不完整翻譯覆蓋後續的完整翻譯

            transcripts.append(finalTranscript)
            interimTranscript = nil
            updateStats()
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
        var shouldPlayTTS = false
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
            let existingTranslation = transcripts[index].translation
            if existingTranslation == nil || existingTranslation?.isEmpty == true {
                shouldPlayTTS = true
            }
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
            let existingTranslation = transcripts[index].translation
            if existingTranslation == nil || existingTranslation?.isEmpty == true {
                shouldPlayTTS = true
            }
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

        // ⭐️ 根據 TTS 播放模式決定是否播放
        if shouldPlayTTS {
            shouldPlayTTS = shouldPlayTTSForMode(detectedLanguage: detectedLanguage)
        }

        if shouldPlayTTS {
            // 判斷翻譯的目標語言
            let targetLangCode = getTargetLanguageCode(for: translatedText)
            enqueueTTS(text: translatedText, languageCode: targetLangCode)
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
            // ⭐️ 檢查當前 STT 服務的連接狀態
            switch currentSTTService.connectionState {
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
