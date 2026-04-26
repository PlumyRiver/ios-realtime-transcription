//
//  TranscriptionViewModel.swift
//  ios_realtime_trans
//
//  轉錄視圖模型：管理錄音、WebSocket 和 UI 狀態
//

import Foundation
import Combine
import AVFoundation
import UIKit
import MediaPlayer

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

/// ⭐️ ViewModel 設定的 UserDefaults 鍵值（放在類外避免 @Observable macro 干擾）
private enum VMSettingsKey: String {
    case sourceLang
    case targetLang
    case ttsPlaybackMode
    case ttsProvider
    case inputMode
    case isEconomyMode
    case sttProvider
    case translationProvider
    case vadThreshold
    case isLocalVADEnabled
    case localVADVolumeThreshold
    case localVADSilenceThreshold
    case isAudioSpeedUpEnabled
    case minSpeechDurationMs
    case isSpeakerMode
    case isAutoLanguageSwitchEnabled
    case autoSwitchConfidenceThreshold
    case isComparisonDisplayMode
    case sttLanguageDetectionMode
    case translationStyle
    case customStylePrompt
    case isLockScreenAutoEnd
}

@Observable
final class TranscriptionViewModel {

    /// ⭐️ Singleton — 確保整個 app 只有一個 ViewModel 實例
    /// 避免 SwiftUI @State 在某些情況下重建視圖時重新建立 ViewModel
    static let shared = TranscriptionViewModel()

    // MARK: - Published Properties

    var sourceLang: Language = .zh {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.sourceLang, value: sourceLang.rawValue)
            // 語言變更時同步更新 ElevenLabs 指定語言
            if sttLanguageDetectionMode == .specifySource {
                updateElevenLabsLanguageCode()
            }
        }
    }
    var targetLang: Language = .en {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.targetLang, value: targetLang.rawValue)
            if sttLanguageDetectionMode == .specifyTarget {
                updateElevenLabsLanguageCode()
            }
        }
    }
    var status: ConnectionStatus = .disconnected

    /// ⭐️ 額度不足對話框
    var showCreditsExhaustedAlert: Bool = false

    /// ⭐️ 編輯對話狀態（放在 ViewModel 避免 ContentView @State 變更觸發全量重繪）
    var showEditSheet: Bool = false
    var editingTranscriptId: UUID?
    var editingInitialText: String = ""

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
            guard !isInitializing else { return }
            audioManager.isSpeakerMode = isSpeakerMode
            saveSetting(.isSpeakerMode, value: isSpeakerMode)
        }
    }

    /// 鎖定螢幕自動結束通話
    var isLockScreenAutoEnd: Bool = false {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.isLockScreenAutoEnd, value: isLockScreenAutoEnd)
        }
    }

    /// TTS 播放模式（四段切換）
    var ttsPlaybackMode: TTSPlaybackMode = .all {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.ttsPlaybackMode, value: ttsPlaybackMode.rawValue)
        }
    }

    /// ⭐️ TTS 服務商（Azure 或 Apple）
    var ttsProvider: TTSProvider = .apple {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.ttsProvider, value: ttsProvider.rawValue)
        }
    }

    /// 自動播放翻譯（TTS）- 計算屬性，向後兼容
    var autoPlayTTS: Bool {
        get { ttsPlaybackMode != .muted }
        set { ttsPlaybackMode = newValue ? .all : .muted }
    }

    /// ⭐️ Apple TTS 播放狀態（手動追蹤，因為 AppleTTSService 不是 @Observable）
    private(set) var isAppleTTSPlaying: Bool = false

    /// ⭐️ Apple TTS 當前播放文本（手動追蹤，用於 UI 更新）
    private(set) var appleTTSCurrentText: String? = nil

    /// TTS 播放中
    var isPlayingTTS: Bool {
        switch ttsProvider {
        case .azure:
            return audioManager.isPlayingTTS
        case .apple:
            return isAppleTTSPlaying  // ⭐️ 使用手動追蹤的狀態
        }
    }

    /// ⭐️ 當前正在播放的 TTS 文本
    var currentPlayingTTSText: String? {
        switch ttsProvider {
        case .azure:
            return audioManager.currentTTSText
        case .apple:
            return appleTTSCurrentText  // ⭐️ 使用手動追蹤的文本
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
            guard !isInitializing else { return }
            if oldValue != inputMode {
                handleInputModeChange()
            }
            saveSetting(.inputMode, value: inputMode.rawValue)
        }
    }

    /// 是否為持續監聽模式
    var isVADMode: Bool {
        inputMode == .vad
    }

    // MARK: - Configuration

    /// 伺服器 URL（Cloud Run 部署的服務）
    var serverURL: String = "chirp3-ios-api-1027448899164.asia-east1.run.app"

    // MARK: - ⭐️ 經濟模式

    /// 經濟模式：使用免費的 Apple STT 和 TTS
    var isEconomyMode: Bool = false {
        didSet {
            guard !isInitializing else { return }
            if oldValue != isEconomyMode {
                if isEconomyMode {
                    print("🌿 [經濟模式] 啟用 - 切換到 Apple STT/TTS")
                    sttProvider = .apple
                    ttsProvider = .apple
                } else {
                    print("💎 [經濟模式] 停用 - 恢復預設提供商")
                    sttProvider = .elevenLabs
                    ttsProvider = .azure
                }
            }
            saveSetting(.isEconomyMode, value: isEconomyMode)
        }
    }

    /// 經濟模式下當前活動的語言（用於雙麥克風切換）
    var economyActiveLanguage: Language = .zh

    /// 經濟模式語言切換統計
    private(set) var lastLanguageSwitchTime: TimeInterval = 0

    /// ⭐️ 自動語言切換（經濟模式專用）
    /// 當識別信心度低於閾值時，自動切換語言重試並比較結果
    var isAutoLanguageSwitchEnabled: Bool = true {
        didSet {
            guard !isInitializing else { return }
            appleSTTService.isAutoLanguageSwitchEnabled = isAutoLanguageSwitchEnabled
            saveSetting(.isAutoLanguageSwitchEnabled, value: isAutoLanguageSwitchEnabled)
            print("🔄 [經濟模式] 自動語言切換: \(isAutoLanguageSwitchEnabled ? "啟用" : "停用")")
        }
    }

    /// 自動切換的信心度閾值（0.0 ~ 1.0）
    var autoSwitchConfidenceThreshold: Float = 0.70 {
        didSet {
            guard !isInitializing else { return }
            appleSTTService.confidenceThreshold = autoSwitchConfidenceThreshold
            saveSetting(.autoSwitchConfidenceThreshold, value: autoSwitchConfidenceThreshold)
            print("🔄 [經濟模式] 信心度閾值: \(String(format: "%.0f", autoSwitchConfidenceThreshold * 100))%")
        }
    }

    /// ⭐️ 比較顯示模式：強制兩種語言都辨識一次，並顯示兩個結果
    /// 用於調試和比較兩種語言的辨識效果
    var isComparisonDisplayMode: Bool = false {
        didSet {
            guard !isInitializing else { return }
            appleSTTService.isComparisonDisplayMode = isComparisonDisplayMode
            saveSetting(.isComparisonDisplayMode, value: isComparisonDisplayMode)
            print("🔬 [經濟模式] 比較顯示模式: \(isComparisonDisplayMode ? "啟用" : "停用")")
        }
    }

    /// ⭐️ STT 提供商選擇（預設 ElevenLabs，延遲更低）
    var sttProvider: STTProvider = .elevenLabs {
        didSet {
            guard !isInitializing else { return }
            if oldValue != sttProvider {
                print("🔄 [STT] 切換提供商: \(oldValue.displayName) → \(sttProvider.displayName)")
                if isRecording {
                    Task { @MainActor in
                        stopRecording()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await startRecording()
                    }
                }
            }
            saveSetting(.sttProvider, value: sttProvider.rawValue)
        }
    }

    /// ⭐️ 翻譯模型選擇（預設 Grok）
    var translationProvider: TranslationProvider = .grok {
        didSet {
            guard !isInitializing else { return }
            if oldValue != translationProvider {
                print("🔄 [翻譯] 切換模型: \(oldValue.displayName) → \(translationProvider.displayName)")
                elevenLabsService.translationProvider = translationProvider
                appleSTTService.translationProvider = translationProvider
            }
            saveSetting(.translationProvider, value: translationProvider.rawValue)
        }
    }

    // MARK: - ⭐️ 翻譯風格

    /// 翻譯風格（預設標準）
    var translationStyle: TranslationStyle = .neutral {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.translationStyle, value: translationStyle.rawValue)
            elevenLabsService.translationStyle = translationStyle
            elevenLabsService.customStylePrompt = translationStyle == .custom ? customStylePrompt : ""
            appleSTTService.translationStyle = translationStyle
            appleSTTService.customStylePrompt = translationStyle == .custom ? customStylePrompt : ""
            print("🎨 [翻譯風格] 切換: \(translationStyle.displayName)")
        }
    }

    /// 自訂風格描述（僅在 translationStyle == .custom 時使用）
    var customStylePrompt: String = "" {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.customStylePrompt, value: customStylePrompt)
            if translationStyle == .custom {
                elevenLabsService.customStylePrompt = customStylePrompt
                appleSTTService.customStylePrompt = customStylePrompt
            }
        }
    }

    // MARK: - ⭐️ STT 語言偵測模式

    /// 語言偵測模式：自動偵測 / 指定來源語言 / 指定目標語言
    var sttLanguageDetectionMode: STTLanguageDetectionMode = .auto {
        didSet {
            guard !isInitializing else { return }
            saveSetting(.sttLanguageDetectionMode, value: sttLanguageDetectionMode.rawValue)
            updateElevenLabsLanguageCode()
            print("🌐 [STT] 語言偵測模式: \(sttLanguageDetectionMode.displayName)")
        }
    }

    /// 根據當前模式計算 ElevenLabs 應使用的語言代碼
    private func getSpecifiedLanguageCode() -> String? {
        switch sttLanguageDetectionMode {
        case .auto:
            return nil  // 不指定，自動偵測
        case .specifySource:
            return mapToElevenLabsCode(sourceLang)
        case .specifyTarget:
            return mapToElevenLabsCode(targetLang)
        }
    }

    /// 將 Language enum 映射為 ElevenLabs 語言代碼
    private func mapToElevenLabsCode(_ lang: Language) -> String {
        switch lang {
        case .isLang: return "is"
        default: return lang.rawValue
        }
    }

    /// 更新 ElevenLabs 的語言代碼設定
    private func updateElevenLabsLanguageCode() {
        elevenLabsService.specifiedLanguageCode = getSpecifiedLanguageCode()
    }

    // MARK: - ElevenLabs VAD 設定

    /// ⭐️ ElevenLabs VAD 閾值（0.0 ~ 1.0）
    /// 越高越嚴格，需要更大聲音才會觸發語音識別
    var vadThreshold: Float = 0.5 {
        didSet {
            guard !isInitializing else { return }
            elevenLabsService.vadThreshold = vadThreshold
            saveSetting(.vadThreshold, value: vadThreshold)
            print("🎚️ [ElevenLabs VAD] 閾值調整: \(vadThreshold)")
        }
    }

    // MARK: - 本地 VAD 設定（節省 STT 費用）
    // ⭐️ 靜音時停止發送音頻，說話時自動恢復
    // ⭐️ 偵測到說話時會發送 0.5 秒的前詞填充

    /// 本地 VAD 開關（預設開啟，節省 STT 費用）
    var isLocalVADEnabled: Bool = true {
        didSet {
            guard !isInitializing else { return }
            audioManager.isVADEnabled = isLocalVADEnabled
            saveSetting(.isLocalVADEnabled, value: isLocalVADEnabled)
            print("🎙️ [本地 VAD] \(isLocalVADEnabled ? "已啟用" : "已停用")")
        }
    }

    /// ⭐️ Silero VAD 語音概率閾值（0.0 ~ 1.0，建議 0.3 ~ 0.7）
    var localVADSpeechThreshold: Float = 0.5 {
        didSet {
            guard !isInitializing else { return }
            audioManager.vadSpeechThreshold = localVADSpeechThreshold
            saveSetting(.localVADVolumeThreshold, value: localVADSpeechThreshold)
            print("🎚️ [Silero VAD] 語音閾值: \(localVADSpeechThreshold)")
        }
    }

    /// 本地 VAD 靜音閾值（秒）- 靜音超過此時間暫停發送
    var localVADSilenceThreshold: TimeInterval = 2.0 {
        didSet {
            guard !isInitializing else { return }
            audioManager.vadSilenceThreshold = localVADSilenceThreshold
            saveSetting(.localVADSilenceThreshold, value: localVADSilenceThreshold)
            print("🎚️ [本地 VAD] 靜音閾值: \(localVADSilenceThreshold)s")
        }
    }

    /// 本地 VAD 當前狀態
    private(set) var localVADState: VADState = .paused

    // MARK: - 音頻加速設定

    /// ⭐️ 音頻加速器（300ms 緩衝，1.5x 加速，節省 33% STT 成本）
    /// 經測試 1.5x 對所有語言都有效，2.0x 對日語等語言無效
    private let audioTimeStretcher = AudioTimeStretcher()

    /// ⭐️ 是否啟用音頻加速（1.5x 速度，300ms 額外延遲）
    /// 注意：Apple STT 免費，不需要加速
    /// 預設開啟，節省 33% STT 成本
    var isAudioSpeedUpEnabled: Bool = true {
        didSet {
            guard !isInitializing else { return }
            audioTimeStretcher.setEnabled(isAudioSpeedUpEnabled)
            BillingService.shared.setSTTSpeedRatio(isAudioSpeedUpEnabled ? 1.5 : 1.0)
            saveSetting(.isAudioSpeedUpEnabled, value: isAudioSpeedUpEnabled)
            if isAudioSpeedUpEnabled {
                print("🚀 [STT] 音頻加速已啟用（1.5x，節省 33% 成本，+300ms 延遲）")
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
            guard !isInitializing else { return }
            elevenLabsService.minSpeechDurationMs = minSpeechDurationMs
            saveSetting(.minSpeechDurationMs, value: minSpeechDurationMs)
            print("🎚️ [VAD] 最小語音長度: \(minSpeechDurationMs)ms")
        }
    }

    /// ⭐️ 即時麥克風音量（0.0 ~ 1.0）
    /// 注意：此變數更新頻繁，僅在設定頁面或通話中聲波顯示時啟用更新
    var currentMicVolume: Float = 0.0

    /// ⭐️ 是否啟用音量監測更新（設定頁面開啟時才啟用）
    var isVolumeMonitoringEnabled: Bool = false

    /// 手動按住錄音狀態，僅用於 UI 顯示聲波活躍狀態
    var isManualInputActive: Bool = false

    /// 給聲波元件直接訂閱，避免音量高頻更新整個 ViewModel
    var micVolumePublisher: AnyPublisher<Float, Never> {
        audioManager.volumePublisher
    }

    /// 通話中是否顯示即時聲波列
    var shouldShowRecordingWaveform: Bool {
        if case .recording = status {
            return true
        }
        return false
    }

    /// 聲波是否代表正在送出/監聽麥克風音訊
    var isRecordingWaveformActive: Bool {
        guard case .recording = status else { return false }

        if !isEconomyMode && inputMode == .vad {
            return true
        }

        return isManualInputActive || audioManager.isTrailingBuffer
    }

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

    /// ⭐️ Google ADK 對話協調 Agent
    private let dialogueAgentService = DialogueAgentService()

    /// TTS 服務（Azure）
    private let ttsService = AzureTTSService()

    /// ⭐️ TTS 服務（Apple 內建）
    private let appleTTSService = AppleTTSService()

    /// TTS 播放隊列
    private var ttsQueue: [(text: String, lang: String)] = []
    private var isProcessingTTS = false
    /// ⭐️ 當前正在合成的文本（用於去重）
    private var currentSynthesizingText: String?

    // MARK: - TTS 穩定對話框系統
    // ⭐️ 等待對話框「穩定」後才播放 TTS，避免 VAD 過早觸發導致一句話被拆成多句

    /// 穩定對話框計時器（等待確認對話框不再變化）
    private var stableDialogTimer: Timer?
    /// 待播放的 TTS（等待對話框穩定後播放）
    private var pendingTTS: (text: String, lang: String, transcriptText: String)?
    /// 對話框穩定等待時間（秒）- Final 翻譯後等待這麼久才播放
    /// ⭐️ 如果在這段時間內對話框被更新（合併），會重新計時
    private let stableDialogDelay: TimeInterval = 1.2
    /// 最後一個 final 的文本（用於判斷是否為新句子）
    private var lastFinalText: String = ""

    // MARK: - TTS 新對話檢測
    /// ⭐️ 最後收到 transcript 的時間（用於判斷是否有新對話進來）
    private var lastTranscriptTime: Date?
    /// ⭐️ TTS 播放前檢查的時間窗口（秒）
    /// 如果在這個時間內有新的 transcript，跳過 TTS 播放
    private let ttsPrePlayCheckWindow: TimeInterval = 0.5

    // MARK: - TTS 保障機制
    /// ⭐️ 已播放的翻譯文本（用於防止重複播放）
    private var playedTranslations: Set<String> = []
    /// ⭐️ 最大記錄數量（避免記憶體無限增長）
    private let maxPlayedTranslationsCount = 50
    /// ⭐️ Agent TTS 進度：每個 source turn 已經安排/播放到哪一段完整翻譯
    private var agentTTSProgressByTurn: [String: String] = [:]
    private let maxAgentTTSProgressCount = 80

    // MARK: - STT Connection Health

    private var sttConnectionWatchdogTimer: Timer?
    private var sttReconnectInProgress = false
    private var lastSTTReconnectAttempt = Date.distantPast
    private let sttConnectionWatchdogInterval: TimeInterval = 5.0
    private let sttReconnectCooldown: TimeInterval = 2.0
    private enum PendingSTTEvent {
        case audio(Data)
        case endUtterance
    }
    private var pendingSTTEvents: [PendingSTTEvent] = []
    private var pendingSTTAudioBytes = 0
    private let maxPendingSTTAudioBytes = 2_000_000

    // MARK: - Dialogue Agent

    private let agentAudioReplayBuffer = AudioRingBuffer(capacitySeconds: 8.0, sampleRate: 16000)
    private var dialogueAgentTasks: [String: Task<Void, Never>] = [:]
    private var lastDialogueAgentResetAt = Date.distantPast
    private let dialogueAgentResetCooldown: TimeInterval = 3.0

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

    /// ⭐️ 初始化標記：@Observable 會讓 didSet 在 init() 中也觸發，
    /// 此 flag 防止初始化期間的連鎖副作用（寫入 UserDefaults、同步服務等）
    private var isInitializing = true

    /// ⭐️ Streaming TTS 穩定計時器
    /// 收到 interim 後等待 1 秒，如果沒有新的更新才開始播放
    private var streamingTTSTimer: Timer?

    // MARK: - ⭐️ 設定持久化（UserDefaults）

    /// 儲存單一設定到 UserDefaults
    private func saveSetting(_ key: VMSettingsKey, value: Any) {
        guard !isInitializing else { return }
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    // MARK: - Initialization

    init() {
        // ⭐️ 只做最小量工作：讀 UserDefaults（快速，~1ms per read）
        // 重的服務同步、Combine 訂閱、生命週期監聽全部延遲到 deferredSetup()
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: VMSettingsKey.sourceLang.rawValue),
           let lang = Language(rawValue: raw) {
            sourceLang = lang
        }
        if let raw = defaults.string(forKey: VMSettingsKey.targetLang.rawValue),
           let lang = Language(rawValue: raw) {
            targetLang = lang
        }
        if defaults.object(forKey: VMSettingsKey.ttsPlaybackMode.rawValue) != nil,
           let mode = TTSPlaybackMode(rawValue: defaults.integer(forKey: VMSettingsKey.ttsPlaybackMode.rawValue)) {
            ttsPlaybackMode = mode
        }
        if let raw = defaults.string(forKey: VMSettingsKey.ttsProvider.rawValue),
           let provider = TTSProvider(rawValue: raw) {
            ttsProvider = provider
        }
        if let raw = defaults.string(forKey: VMSettingsKey.inputMode.rawValue),
           let mode = InputMode(rawValue: raw) {
            inputMode = mode
        }
        if let raw = defaults.string(forKey: VMSettingsKey.sttProvider.rawValue),
           let provider = STTProvider(rawValue: raw) {
            sttProvider = provider
        }
        if let raw = defaults.string(forKey: VMSettingsKey.translationProvider.rawValue),
           let provider = TranslationProvider(rawValue: raw) {
            translationProvider = provider
        }
        if defaults.object(forKey: VMSettingsKey.isEconomyMode.rawValue) != nil {
            isEconomyMode = defaults.bool(forKey: VMSettingsKey.isEconomyMode.rawValue)
            if isEconomyMode {
                sttProvider = .apple
                ttsProvider = .apple
            }
        }
        if defaults.object(forKey: VMSettingsKey.vadThreshold.rawValue) != nil {
            vadThreshold = defaults.float(forKey: VMSettingsKey.vadThreshold.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.isLocalVADEnabled.rawValue) != nil {
            isLocalVADEnabled = defaults.bool(forKey: VMSettingsKey.isLocalVADEnabled.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.localVADVolumeThreshold.rawValue) != nil {
            let saved = defaults.float(forKey: VMSettingsKey.localVADVolumeThreshold.rawValue)
            if saved < 0.1 {
                localVADSpeechThreshold = 0.5
                saveSetting(.localVADVolumeThreshold, value: 0.5)
            } else {
                localVADSpeechThreshold = saved
            }
        }
        if defaults.object(forKey: VMSettingsKey.localVADSilenceThreshold.rawValue) != nil {
            localVADSilenceThreshold = defaults.double(forKey: VMSettingsKey.localVADSilenceThreshold.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.isAudioSpeedUpEnabled.rawValue) != nil {
            isAudioSpeedUpEnabled = defaults.bool(forKey: VMSettingsKey.isAudioSpeedUpEnabled.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.minSpeechDurationMs.rawValue) != nil {
            minSpeechDurationMs = defaults.integer(forKey: VMSettingsKey.minSpeechDurationMs.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.isSpeakerMode.rawValue) != nil {
            isSpeakerMode = defaults.bool(forKey: VMSettingsKey.isSpeakerMode.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.isAutoLanguageSwitchEnabled.rawValue) != nil {
            isAutoLanguageSwitchEnabled = defaults.bool(forKey: VMSettingsKey.isAutoLanguageSwitchEnabled.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.autoSwitchConfidenceThreshold.rawValue) != nil {
            autoSwitchConfidenceThreshold = defaults.float(forKey: VMSettingsKey.autoSwitchConfidenceThreshold.rawValue)
        }
        if defaults.object(forKey: VMSettingsKey.isComparisonDisplayMode.rawValue) != nil {
            isComparisonDisplayMode = defaults.bool(forKey: VMSettingsKey.isComparisonDisplayMode.rawValue)
        }
        if let raw = defaults.string(forKey: VMSettingsKey.sttLanguageDetectionMode.rawValue),
           let mode = STTLanguageDetectionMode(rawValue: raw) {
            sttLanguageDetectionMode = mode
        }
        if let raw = defaults.string(forKey: VMSettingsKey.translationStyle.rawValue),
           let style = TranslationStyle(rawValue: raw) {
            translationStyle = style
        }
        if let saved = defaults.string(forKey: VMSettingsKey.customStylePrompt.rawValue) {
            customStylePrompt = saved
        }
        if defaults.object(forKey: VMSettingsKey.isLockScreenAutoEnd.rawValue) != nil {
            isLockScreenAutoEnd = defaults.bool(forKey: VMSettingsKey.isLockScreenAutoEnd.rawValue)
        }

        print("💾 [設定] 已載入: \(sourceLang.shortName)→\(targetLang.shortName), STT=\(sttProvider.shortName), 翻譯=\(translationProvider.shortName), 經濟=\(isEconomyMode), 語言偵測=\(sttLanguageDetectionMode.shortName), 風格=\(translationStyle.displayName)")

        // ⭐️ init 到此結束 — UI 可以立刻渲染
        // 重的工作（服務同步、Combine、生命週期）延遲到 deferredSetup()
        // 由 ContentView.task 呼叫，保證第一幀已渲染
    }

    /// ⭐️ 延遲初始化：Combine 訂閱 + 服務同步 + 生命週期監聽
    /// 由 ContentView.task 呼叫，確保 UI 第一幀已渲染後才執行
    func deferredSetup() async {
        guard isInitializing else { return }
        let t0 = Date()

        setupSubscriptions()
        print("⏱️ [deferredSetup] setupSubscriptions: \(Int(Date().timeIntervalSince(t0)*1000))ms")
        await Task.yield()

        // 同步設定到各服務（快速，只是屬性賦值）
        audioTimeStretcher.setEnabled(isAudioSpeedUpEnabled)
        BillingService.shared.setSTTSpeedRatio(isAudioSpeedUpEnabled ? 1.5 : 1.0)
        elevenLabsService.translationProvider = translationProvider
        appleSTTService.translationProvider = translationProvider
        elevenLabsService.translationStyle = translationStyle
        elevenLabsService.customStylePrompt = translationStyle == .custom ? customStylePrompt : ""
        appleSTTService.translationStyle = translationStyle
        appleSTTService.customStylePrompt = translationStyle == .custom ? customStylePrompt : ""
        audioManager.isVADEnabled = isLocalVADEnabled
        audioManager.vadSpeechThreshold = localVADSpeechThreshold
        audioManager.vadSilenceThreshold = localVADSilenceThreshold
        audioManager.isSpeakerMode = isSpeakerMode
        elevenLabsService.vadThreshold = vadThreshold
        elevenLabsService.minSpeechDurationMs = minSpeechDurationMs
        elevenLabsService.specifiedLanguageCode = getSpecifiedLanguageCode()
        appleSTTService.isAutoLanguageSwitchEnabled = isAutoLanguageSwitchEnabled
        appleSTTService.confidenceThreshold = autoSwitchConfidenceThreshold
        appleSTTService.isComparisonDisplayMode = isComparisonDisplayMode

        print("⏱️ [deferredSetup] 服務同步: \(Int(Date().timeIntervalSince(t0)*1000))ms")
        isInitializing = false
        await Task.yield()

        setupLifecycleObservers()
        print("⏱️ [deferredSetup] 全部完成: \(Int(Date().timeIntervalSince(t0)*1000))ms")
        print("✅ [ViewModel] 延遲初始化完成")
    }

    /// ⭐️ 預熱 Apple TTS（由 ContentView 在 UI 穩定後呼叫）
    private var ttsWarmedUp = false
    func warmUpTTSIfNeeded() {
        guard !ttsWarmedUp else { return }
        ttsWarmedUp = true

        let srcLocale = sourceLang.azureLocale
        let tgtLocale = targetLang.azureLocale
        appleTTSService.preWarmLanguages([srcLocale, tgtLocale])
        print("🔥 [TTS] 啟動風暴後預熱: \(srcLocale), \(tgtLocale)")
    }

    /// ⭐️ 低優先權預熱錄音管線；不在 init 搶 UI，真正開始錄音時仍會同步保底初始化。
    private var audioPipelineWarmedUp = false
    func warmUpAudioPipelineIfNeeded() {
        guard !audioPipelineWarmedUp else { return }
        audioPipelineWarmedUp = true
        audioManager.prewarmRecordingPipeline()
    }

    /// ⭐️ 預取 ElevenLabs token（在 App 出現時調用一次）
    func prefetchElevenLabsToken() {
        elevenLabsService.prefetchToken(serverURL: serverURL)
    }

    // MARK: - App Lifecycle Management

    /// 進入背景的時間（用於判斷是否超過 5 分鐘）
    private var backgroundEntryTime: Date?
    /// 背景超時（5 分鐘）
    private let backgroundTimeout: TimeInterval = 5 * 60
    /// 前台閒置超時（10 分鐘無轉錄）
    private let foregroundIdleTimeout: TimeInterval = 10 * 60
    /// 前台閒置計時器
    private var idleTimer: Timer?
    /// 是否因為進入背景而暫停音訊
    private var isPausedForBackground: Bool = false

    /// ⭐️ 閒置翻譯檢查：STT 無新文字 5 秒後，掃描未翻譯的對話並重試
    private var translationIdleTimer: Timer?
    /// ⭐️ 正在補翻完整 final 的原文，避免同一句被舊 interim 回調連續觸發多次
    private var pendingFullRetranslationTexts: Set<String> = []

    /// ⭐️ 設置 App 生命週期監聽（在 init 後呼叫）
    func setupLifecycleObservers() {
        // 進入背景：停止發送音訊，保持連線
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEnterBackground()
        }

        // 回到前台：檢查時間，恢復或斷線
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEnterForeground()
        }

        // 螢幕鎖定：立即斷線
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenLock()
        }

        print("✅ [Lifecycle] App 生命週期監聽已設定")
    }

    /// 進入背景：停止音訊，保持連線
    @MainActor
    private func handleEnterBackground() {
        guard isRecording else { return }
        backgroundEntryTime = Date()
        idleTimer?.invalidate()
        idleTimer = nil
        // 切 App 永遠持續錄音
        print("📱 [Lifecycle] 進入背景 → 持續錄音")
    }

    /// 回到前台
    @MainActor
    private func handleEnterForeground() {
        guard isRecording else { return }

        if let entryTime = backgroundEntryTime {
            let elapsed = Date().timeIntervalSince(entryTime)
            if elapsed >= backgroundTimeout {
                print("📱 [Lifecycle] 背景超過 \(Int(elapsed))s（>\(Int(backgroundTimeout))s）→ 自動斷線")
                endCall()
                return
            }
            print("📱 [Lifecycle] 回到前台（背景 \(Int(elapsed))s）")
        }

        backgroundEntryTime = nil
        audioManager.recoverAudioEngine()
        attemptSTTReconnectIfNeeded(reason: "回到前台")
        startIdleTimer()
        startSTTConnectionWatchdog()
    }

    /// 螢幕鎖定
    @MainActor
    private func handleScreenLock() {
        guard isRecording else { return }
        if isLockScreenAutoEnd {
            print("🔒 [Lifecycle] 螢幕鎖定 → 自動結束通話（設定啟用）")
            endCall()
        } else {
            print("🔒 [Lifecycle] 螢幕鎖定 → 持續錄音")
        }
    }

    /// ⭐️ 啟動前台閒置計時器（10 分鐘無轉錄 → 自動斷線）
    func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: foregroundIdleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                print("⏰ [Lifecycle] 前台閒置 \(Int(self.foregroundIdleTimeout))s 無轉錄 → 自動斷線")
                self.endCall()
            }
        }
    }

    /// ⭐️ 重置閒置計時器（收到轉錄時呼叫）
    func resetIdleTimer() {
        guard isRecording, !isPausedForBackground else { return }
        startIdleTimer()
    }

    /// ⭐️ 啟動 STT 連線健康檢查。
    /// 長時間安靜、切到持續監聽或背景恢復後，WebSocket 可能已被服務端關閉；
    /// 若 UI 仍在錄音但 STT 已斷線，音頻會被 sendAudio 丟棄，所以這裡主動重連。
    private func startSTTConnectionWatchdog() {
        sttConnectionWatchdogTimer?.invalidate()
        sttConnectionWatchdogTimer = Timer.scheduledTimer(withTimeInterval: sttConnectionWatchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.attemptSTTReconnectIfNeeded(reason: "連線健康檢查")
            }
        }
    }

    private func stopSTTConnectionWatchdog() {
        sttConnectionWatchdogTimer?.invalidate()
        sttConnectionWatchdogTimer = nil
    }

    @MainActor
    private func processOutgoingAudioForSTT(_ data: Data) {
        if isAudioSpeedUpEnabled && sttProvider != .apple {
            if let processedData = audioTimeStretcher.process(data: data) {
                sendOrQueueSTTAudio(processedData)
            }
        } else {
            sendOrQueueSTTAudio(data)
        }
    }

    @MainActor
    private func sendOrQueueSTTAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        agentAudioReplayBuffer.write(data)

        switch currentSTTService.connectionState {
        case .connected:
            drainPendingSTTEventsIfConnected()
            currentSTTService.sendAudio(data: data)
        case .connecting:
            queuePendingSTTAudio(data)
        case .disconnected, .error:
            queuePendingSTTAudio(data)
            attemptSTTReconnectIfNeeded(reason: "送音前發現 STT 未連線")
        }
    }

    @MainActor
    private func handleEndUtterance() {
        guard isRecording else { return }

        flushAudioSpeedupForUtteranceEnd()

        switch currentSTTService.connectionState {
        case .connected:
            drainPendingSTTEventsIfConnected()
            currentSTTService.sendEndUtterance()
        case .connecting:
            queuePendingEndUtterance()
        case .disconnected, .error:
            queuePendingEndUtterance()
            attemptSTTReconnectIfNeeded(reason: "結束語句前發現 STT 未連線")
        }
    }

    @MainActor
    private func flushAudioSpeedupForUtteranceEnd() {
        guard isAudioSpeedUpEnabled, sttProvider != .apple else { return }

        if let remainingData = audioTimeStretcher.flush(), !remainingData.isEmpty {
            sendOrQueueSTTAudio(remainingData)
        }
        audioTimeStretcher.reset()
    }

    private func resetPendingSTTEvents() {
        pendingSTTEvents.removeAll()
        pendingSTTAudioBytes = 0
    }

    private func queuePendingSTTAudio(_ data: Data) {
        pendingSTTEvents.append(.audio(data))
        pendingSTTAudioBytes += data.count
        trimPendingSTTEventsIfNeeded()
    }

    private func queuePendingEndUtterance() {
        pendingSTTEvents.append(.endUtterance)
        print("⏳ [STT Queue] STT 尚未連線，暫存結束語句")
    }

    private func trimPendingSTTEventsIfNeeded() {
        guard pendingSTTAudioBytes > maxPendingSTTAudioBytes else { return }

        var droppedAudioBytes = 0
        while pendingSTTAudioBytes > maxPendingSTTAudioBytes, !pendingSTTEvents.isEmpty {
            let removed = pendingSTTEvents.removeFirst()
            if case .audio(let data) = removed {
                pendingSTTAudioBytes -= data.count
                droppedAudioBytes += data.count
            }
        }

        if droppedAudioBytes > 0 {
            print("⚠️ [STT Queue] 暫存音頻過大，丟棄最舊 \(droppedAudioBytes) bytes")
        }
    }

    @MainActor
    private func drainPendingSTTEventsIfConnected() {
        guard currentSTTService.connectionState == .connected else { return }
        guard !pendingSTTEvents.isEmpty else { return }

        let events = pendingSTTEvents
        let audioBytes = pendingSTTAudioBytes
        resetPendingSTTEvents()

        print("📤 [STT Queue] 補送暫存事件 \(events.count) 個（音頻 \(audioBytes) bytes）")
        for event in events {
            switch event {
            case .audio(let data):
                currentSTTService.sendAudio(data: data)
            case .endUtterance:
                currentSTTService.sendEndUtterance()
            }
        }
    }

    @MainActor
    private func attemptSTTReconnectIfNeeded(reason: String) {
        guard isRecording else { return }

        switch currentSTTService.connectionState {
        case .connected, .connecting:
            return
        case .disconnected, .error:
            break
        }

        let now = Date()
        guard !sttReconnectInProgress,
              now.timeIntervalSince(lastSTTReconnectAttempt) >= sttReconnectCooldown else {
            return
        }

        sttReconnectInProgress = true
        lastSTTReconnectAttempt = now

        let service = currentSTTService
        let providerName = sttProvider.displayName
        let source = sourceLang
        let target = targetLang

        print("🔄 [STT Watchdog] \(reason)：\(providerName) 已斷線，嘗試重連")
        service.connect(serverURL: serverURL, sourceLang: source, targetLang: target)

        Task { @MainActor in
            let start = Date()
            let timeout: TimeInterval = providerName.contains("ElevenLabs") ? 20.0 : 10.0

            while Date().timeIntervalSince(start) < timeout {
                if service.connectionState == .connected {
                    let elapsed = Date().timeIntervalSince(start)
                    print("✅ [STT Watchdog] \(providerName) 重連成功（\(String(format: "%.2f", elapsed))s）")
                    self.sttReconnectInProgress = false
                    self.drainPendingSTTEventsIfConnected()

                    if self.inputMode == .vad {
                        self.audioManager.startSending()
                    }
                    return
                }

                if case .error(let message) = service.connectionState {
                    print("⚠️ [STT Watchdog] \(providerName) 重連中遇到錯誤: \(message)")
                    break
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            self.sttReconnectInProgress = false
            print("⚠️ [STT Watchdog] \(providerName) 重連尚未成功，稍後會再試")
        }
    }

    // MARK: - Dialogue Agent Integration

    @MainActor
    private func scheduleDialogueAgentProcessing(for transcript: TranscriptMessage) {
        scheduleDialogueAgent(for: transcript, mode: .realtime, delay: 0)

        if transcripts.filter({ $0.isFinal }).count >= 2 {
            scheduleDialogueAgent(for: transcript, mode: .consolidate, delay: 0.8)
        }
    }

    @MainActor
    private func scheduleDialogueAgent(for transcript: TranscriptMessage, mode: DialogueAgentMode, delay: TimeInterval) {
        let request = makeDialogueAgentRequest(for: transcript, mode: mode)
        let key = "\(transcript.id.uuidString)-\(mode.rawValue)"
        let service = dialogueAgentService
        let serverURL = serverURL

        dialogueAgentTasks[key]?.cancel()
        dialogueAgentTasks[key] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            do {
                let response = try await service.createPlan(
                    serverURL: serverURL,
                    request: request,
                    timeout: mode == .consolidate ? 35 : 15
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.dialogueAgentTasks[key] = nil
                    self.applyDialogueAgentPlan(response, anchorTranscriptID: transcript.id, mode: mode)
                }
            } catch {
                await MainActor.run {
                    self?.dialogueAgentTasks[key] = nil
                    print("⚠️ [Dialogue Agent] \(mode.rawValue) 失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    private func makeDialogueAgentRequest(for transcript: TranscriptMessage, mode: DialogueAgentMode) -> DialogueAgentRequest {
        let previousTurns = transcripts
            .filter { $0.id != transcript.id && $0.isFinal }
            .suffix(2)
            .map {
                DialogueAgentPreviousTurn(
                    id: $0.id.uuidString,
                    original: $0.text,
                    translation: $0.translation
                )
            }
        let playedTTS = (
            Array(playedTranslations).map { DialogueAgentPlayedTTS(text: $0) } +
            Array(agentTTSProgressByTurn.values).suffix(8).map { DialogueAgentPlayedTTS(text: $0) }
        )
            .suffix(8)
        let isLikelyNoise = looksLikeAgentNoise(text: transcript.text) ||
            (transcript.confidence > 0 && transcript.confidence < 0.35)

        return DialogueAgentRequest(
            agentMode: mode,
            sourceLang: sourceLang.rawValue,
            targetLang: targetLang.rawValue,
            fragments: [
                DialogueAgentFragment(
                    id: transcript.id.uuidString,
                    text: transcript.text,
                    isFinal: transcript.isFinal,
                    timestampMs: Int(transcript.timestamp.timeIntervalSince1970 * 1000),
                    confidence: transcript.confidence > 0 ? transcript.confidence : nil
                )
            ],
            previousTurns: Array(previousTurns),
            playedTTS: Array(playedTTS),
            audioHealth: DialogueAgentAudioHealth(
                repeatedNoiseCount: isLikelyNoise ? 4 : nil,
                noValidSpeechMs: isLikelyNoise ? 9000 : nil
            )
        )
    }

    @MainActor
    private func applyDialogueAgentPlan(
        _ response: DialogueAgentResponse,
        anchorTranscriptID: UUID,
        mode: DialogueAgentMode
    ) {
        if response.audioRecovery.shouldReset {
            dropNoisyTranscriptsIfNeeded(response: response, anchorTranscriptID: anchorTranscriptID)
            resetSTTStreamFromDialogueAgent(recovery: response.audioRecovery)
        }

        let rawUsableTurns = response.normalizedTurns.filter { turn in
            turn.status != "drop" && !turn.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let usableTurns = coalesceDialogueAgentTurns(rawUsableTurns)
        guard !usableTurns.isEmpty else { return }

        let sourceIDs = Set(usableTurns.flatMap(\.sourceFragmentIds))
        var affectedIndices: [Int] = transcripts.enumerated().compactMap { index, transcript in
            sourceIDs.contains(transcript.id.uuidString) ? index : nil
        }

        if mode == .realtime {
            affectedIndices = transcripts.enumerated().compactMap { index, transcript in
                transcript.id == anchorTranscriptID ? index : nil
            }
        }

        guard let insertIndex = affectedIndices.min() else { return }
        let sortedIndices = Array(Set(affectedIndices)).sorted()
        if mode == .consolidate,
           !isSafeDialogueAgentConsolidation(
                usableTurns: usableTurns,
                affectedIndices: sortedIndices,
                anchorTranscriptID: anchorTranscriptID
           ) {
            print("🛡️ [Dialogue Agent] 拒絕不安全合併，保留原泡泡")
            return
        }

        let fallbackTranscript = transcripts[insertIndex]
        let shouldReplaceShape = usableTurns.count != sortedIndices.count || sortedIndices.count > 1
        let shouldApplyTranslation = usableTurns.contains { !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard shouldReplaceShape || shouldApplyTranslation else { return }

        if shouldReplaceShape {
            cancelTTSForMergedDialog(oldText: fallbackTranscript.text)
        }

        let replacements = usableTurns.enumerated().map { offset, turn in
            makeTranscriptMessage(
                from: turn,
                fallback: fallbackTranscript,
                preserveID: offset == 0 ? fallbackTranscript.id : nil,
                confidence: response.confidence
            )
        }

        for index in sortedIndices.reversed() {
            transcripts.remove(at: index)
        }
        transcripts.insert(contentsOf: replacements, at: insertIndex)

        lastFinalText = transcripts.last?.text ?? ""
        updateStats()
        playDialogueAgentTTSPlan(response, turns: usableTurns)

        print("🧠 [Dialogue Agent] 套用 \(mode.rawValue): turns=\(usableTurns.count), actions=\(response.actions.map(\.type).joined(separator: ","))")
    }

    private func makeTranscriptMessage(
        from turn: DialogueAgentTurn,
        fallback: TranscriptMessage,
        preserveID: UUID?,
        confidence: Double
    ) -> TranscriptMessage {
        TranscriptMessage(
            id: preserveID ?? UUID(),
            text: turn.original,
            isFinal: true,
            confidence: confidence,
            language: turn.detectedLang,
            converted: fallback.converted,
            originalText: fallback.originalText,
            speakerTag: fallback.speakerTag,
            timestamp: fallback.timestamp,
            translation: turn.translation.isEmpty ? fallback.translation : turn.translation,
            translationSegments: nil,
            isIntroduction: fallback.isIntroduction
        )
    }

    private func coalesceDialogueAgentTurns(_ turns: [DialogueAgentTurn]) -> [DialogueAgentTurn] {
        var repairedTurns = turns
        for index in repairedTurns.indices {
            let turn = repairedTurns[index]
            guard normalizedAgentLang(turn.detectedLang) == "zh",
                  isHanOnlyDialogueText(turn.original) else {
                continue
            }

            let previousLang = index > repairedTurns.startIndex
                ? normalizedAgentLang(repairedTurns[repairedTurns.index(before: index)].detectedLang)
                : ""
            let nextIndex = repairedTurns.index(after: index)
            let nextLang = nextIndex < repairedTurns.endIndex
                ? normalizedAgentLang(repairedTurns[nextIndex].detectedLang)
                : ""

            if previousLang == "ja", nextLang == "ja" {
                repairedTurns[index] = DialogueAgentTurn(
                    id: turn.id,
                    sourceFragmentIds: turn.sourceFragmentIds,
                    original: turn.original,
                    detectedLang: "ja",
                    translateTo: "zh",
                    translation: turn.translation,
                    status: turn.status
                )
            }
        }

        var coalesced: [DialogueAgentTurn] = []
        for turn in repairedTurns {
            guard let previous = coalesced.last,
                  previous.status != "drop",
                  turn.status != "drop",
                  normalizedAgentLang(previous.detectedLang) == normalizedAgentLang(turn.detectedLang),
                  normalizedAgentLang(previous.translateTo) == normalizedAgentLang(turn.translateTo) else {
                coalesced.append(turn)
                continue
            }

            coalesced[coalesced.count - 1] = DialogueAgentTurn(
                id: previous.id,
                sourceFragmentIds: uniqueAgentSourceIDs(previous.sourceFragmentIds + turn.sourceFragmentIds),
                original: joinAgentDialogueText(previous.original, turn.original),
                detectedLang: previous.detectedLang,
                translateTo: previous.translateTo,
                translation: joinAgentDialogueText(previous.translation, turn.translation),
                status: mergedAgentTurnStatus(previous.status, turn.status)
            )
        }

        return coalesced
    }

    private func normalizedAgentLang(_ value: String) -> String {
        let lang = value.lowercased()
        if lang.hasPrefix("zh") || lang.contains("chinese") { return "zh" }
        if lang.hasPrefix("ja") || lang.contains("japanese") { return "ja" }
        if lang.hasPrefix("ko") || lang.contains("korean") { return "ko" }
        if lang.hasPrefix("en") || lang.contains("english") { return "en" }
        return lang
    }

    private func isHanOnlyDialogueText(_ text: String) -> Bool {
        let meaningfulScalars = text.unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar) ||
                CharacterSet.decimalDigits.contains(scalar) {
                return false
            }
            return true
        }
        guard !meaningfulScalars.isEmpty else { return false }
        return meaningfulScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func uniqueAgentSourceIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func joinAgentDialogueText(_ left: String, _ right: String) -> String {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if let last = a.last,
           let first = b.first,
           isAsciiLetterOrDigit(last),
           isAsciiLetterOrDigit(first) {
            return "\(a) \(b)"
        }
        return a + b
    }

    private func isAsciiLetterOrDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private func mergedAgentTurnStatus(_ left: String, _ right: String) -> String {
        if left == "drop" || right == "drop" { return "drop" }
        if left == "needs_retry" || right == "needs_retry" { return "needs_retry" }
        if left == "stable", right == "stable" { return "stable" }
        return "provisional"
    }

    @MainActor
    private func playDialogueAgentTTSPlan(_ response: DialogueAgentResponse, turns: [DialogueAgentTurn]) {
        let turnById = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        let ttsPlanMatchesTurns = response.ttsPlan.count == turns.count &&
            response.ttsPlan.allSatisfy { turnById[$0.sourceTurnId] != nil }

        if !ttsPlanMatchesTurns {
            playCoalescedDialogueAgentTTS(turns)
            return
        }

        for item in response.ttsPlan {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard item.playPolicy == "play_now" ||
                    item.playPolicy == "wait_for_stability" ||
                    item.playPolicy == "replace_previous" else {
                continue
            }

            let detectedLanguage = turnById[item.sourceTurnId]?.detectedLang
            guard shouldPlayTTSForMode(detectedLanguage: detectedLanguage) else { continue }

            let progressKey = agentTTSProgressKey(for: item, turnById: turnById)
            let playableText = nextAgentTTSPlayableText(
                fullText: text,
                progressKey: progressKey,
                playPolicy: item.playPolicy
            )
            guard !playableText.isEmpty else {
                print("⏭️ [Dialogue Agent TTS] 已播放到最新，跳過: \(progressKey)")
                continue
            }

            if item.playPolicy == "replace_previous" {
                cancelTTSForMergedDialog(oldText: playableText)
            }
            enqueueDialogueAgentTTS(text: playableText, languageCode: item.languageCode, playNow: item.playPolicy == "play_now")
        }
    }

    @MainActor
    private func playCoalescedDialogueAgentTTS(_ turns: [DialogueAgentTurn]) {
        for turn in turns {
            let text = turn.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard shouldPlayTTSForMode(detectedLanguage: turn.detectedLang) else { continue }

            let progressKey = agentTTSProgressKey(for: turn)
            let playableText = nextAgentTTSPlayableText(
                fullText: text,
                progressKey: progressKey,
                playPolicy: turn.status == "stable" ? "play_now" : "wait_for_stability"
            )
            guard !playableText.isEmpty else { continue }
            enqueueDialogueAgentTTS(
                text: playableText,
                languageCode: languageCodeForAgentTTS(turn.translateTo),
                playNow: turn.status == "stable"
            )
        }
    }

    @MainActor
    private func isSafeDialogueAgentConsolidation(
        usableTurns: [DialogueAgentTurn],
        affectedIndices: [Int],
        anchorTranscriptID: UUID
    ) -> Bool {
        guard !affectedIndices.isEmpty,
              let anchorIndex = transcripts.firstIndex(where: { $0.id == anchorTranscriptID }) else {
            return false
        }

        if affectedIndices == [anchorIndex] {
            return true
        }

        // 只允許 Agent 改寫目前尾端的相鄰泡泡；舊回應不可回頭吞掉後面新出現的對話。
        guard anchorIndex == transcripts.indices.last,
              affectedIndices.last == anchorIndex,
              affectedIndices.count <= 3,
              affectedIndices == Array(affectedIndices[0]...anchorIndex) else {
            return false
        }

        let mergedOriginal = normalizeTextForComparison(usableTurns.map(\.original).joined())
        for index in affectedIndices {
            let original = normalizeTextForComparison(transcripts[index].text)
            if !original.isEmpty && !mergedOriginal.contains(original) {
                return false
            }
        }

        let affectedTexts = affectedIndices.map { transcripts[$0].text }
        return canSafelyMergeAgentTexts(affectedTexts)
    }

    private func canSafelyMergeAgentTexts(_ texts: [String]) -> Bool {
        guard let first = texts.first, !first.isEmpty else { return false }
        var context = first

        for next in texts.dropFirst() {
            if shouldMergeTexts(newText: next, lastText: context) ||
                isLocationContinuation(next) ||
                isPureTrailingDetail(next) ||
                (hasSharedMeaningfulToken(context, next) && hasDetailCue(next)) {
                context += next
                continue
            }
            return false
        }

        return true
    }

    private func isLocationContinuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("在") ||
            trimmed.hasPrefix("到") ||
            trimmed.hasPrefix("於") ||
            trimmed.lowercased().hasPrefix("at ") ||
            trimmed.lowercased().hasPrefix("in ")
    }

    private func isPureTrailingDetail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return false }
        if trimmed.range(of: #"^[0-9０-９]+[元円塊個杯份分點時年月日公里kmKM%％]*$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.hasPrefix("共") ||
            trimmed.hasPrefix("總共") ||
            trimmed.hasPrefix("一共") ||
            trimmed.hasPrefix("還有") ||
            trimmed.hasPrefix("以及")
    }

    private func hasDetailCue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isLocationContinuation(trimmed) ||
            trimmed.range(of: #"[0-9０-９]"#, options: .regularExpression) != nil ||
            trimmed.contains("元") ||
            trimmed.contains("円") ||
            trimmed.contains("點") ||
            trimmed.contains("時")
    }

    private func hasSharedMeaningfulToken(_ lhs: String, _ rhs: String) -> Bool {
        let lhsTokens = Set(cjkBigrams(lhs))
        guard !lhsTokens.isEmpty else { return false }
        return cjkBigrams(rhs).contains { lhsTokens.contains($0) }
    }

    private func cjkBigrams(_ text: String) -> [String] {
        let chars = text.unicodeScalars
            .filter { scalar in
                (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                    (0x3040...0x30FF).contains(Int(scalar.value))
            }
            .map { String($0) }
        guard chars.count >= 2 else { return [] }
        return (0..<(chars.count - 1)).map { chars[$0] + chars[$0 + 1] }
    }

    private func agentTTSProgressKey(for turn: DialogueAgentTurn) -> String {
        let sourceKey = turn.sourceFragmentIds.isEmpty ? turn.id : turn.sourceFragmentIds.joined(separator: "+")
        return "\(sourceKey)->\(turn.translateTo)"
    }

    private func languageCodeForAgentTTS(_ lang: String) -> String {
        switch normalizedAgentLang(lang) {
        case "zh":
            return "zh-TW"
        case "ja":
            return "ja-JP"
        case "ko":
            return "ko-KR"
        default:
            return "en-US"
        }
    }

    private func agentTTSProgressKey(
        for item: DialogueAgentTTSPlanItem,
        turnById: [String: DialogueAgentTurn]
    ) -> String {
        guard let turn = turnById[item.sourceTurnId] else {
            return item.sourceTurnId
        }
        let sourceKey = turn.sourceFragmentIds.isEmpty ? item.sourceTurnId : turn.sourceFragmentIds.joined(separator: "+")
        return "\(sourceKey)->\(turn.translateTo)"
    }

    @MainActor
    private func nextAgentTTSPlayableText(fullText: String, progressKey: String, playPolicy: String) -> String {
        let previous = agentTTSProgressByTurn[progressKey] ?? ""
        let delta = calculateNewTTSContent(playedText: previous, fullTranslation: fullText)

        if fullText.count >= previous.count || playPolicy == "replace_previous" {
            agentTTSProgressByTurn[progressKey] = fullText
        }
        trimAgentTTSProgressIfNeeded()
        return delta
    }

    private func trimAgentTTSProgressIfNeeded() {
        guard agentTTSProgressByTurn.count > maxAgentTTSProgressCount else { return }
        let keysToRemove = Array(agentTTSProgressByTurn.keys.prefix(agentTTSProgressByTurn.count - maxAgentTTSProgressCount))
        for key in keysToRemove {
            agentTTSProgressByTurn.removeValue(forKey: key)
        }
    }

    @MainActor
    private func enqueueDialogueAgentTTS(text: String, languageCode: String, playNow: Bool) {
        let normalized = normalizeTextForComparison(text)
        guard !normalized.isEmpty else { return }
        guard !playedTranslations.contains(normalized) else { return }
        guard pendingTTS == nil || normalizeTextForComparison(pendingTTS!.text) != normalized else { return }
        guard !ttsQueue.contains(where: { normalizeTextForComparison($0.text) == normalized }) else { return }

        if playNow {
            directEnqueueTTS(text: text, languageCode: languageCode)
        } else {
            enqueueTTS(text: text, languageCode: languageCode)
        }
    }

    @MainActor
    private func dropNoisyTranscriptsIfNeeded(response: DialogueAgentResponse, anchorTranscriptID: UUID) {
        guard response.audioRecovery.shouldReset else { return }

        let actionTargetIDs = Set(response.actions.flatMap(\.targetIds))
        let dropText = response.audioRecovery.dropTranscriptText
        let indices = transcripts.enumerated().compactMap { index, transcript -> Int? in
            if actionTargetIDs.contains(transcript.id.uuidString) { return index }
            if transcript.id == anchorTranscriptID { return index }
            if !dropText.isEmpty && (dropText.contains(transcript.text) || transcript.text.contains(dropText)) {
                return index
            }
            return nil
        }

        for index in Array(Set(indices)).sorted().reversed() {
            print("🧹 [Dialogue Agent] 移除疑似雜音 transcript: \"\(transcripts[index].text.prefix(30))...\"")
            transcripts.remove(at: index)
        }
        updateStats()
    }

    @MainActor
    private func resetSTTStreamFromDialogueAgent(recovery: DialogueAgentAudioRecovery) {
        guard isRecording else { return }

        let now = Date()
        guard now.timeIntervalSince(lastDialogueAgentResetAt) >= dialogueAgentResetCooldown else {
            print("⏭️ [Dialogue Agent] 重置過於頻繁，跳過")
            return
        }
        lastDialogueAgentResetAt = now

        let replayAudio = agentAudioReplayBuffer.readLast(4.0)
        resetPendingSTTEvents()
        if !replayAudio.isEmpty {
            queuePendingSTTAudio(replayAudio)
            queuePendingEndUtterance()
            print("🔁 [Dialogue Agent] 已暫存最近 \(String(format: "%.1f", agentAudioReplayBuffer.bufferedDuration)) 秒音訊，等待 STT 重連後重送")
        }

        print("🔄 [Dialogue Agent] 重置 STT 音訊流: \(recovery.reason)")
        currentSTTService.disconnect()
        sttReconnectInProgress = false
        attemptSTTReconnectIfNeeded(reason: "Dialogue Agent 要求音訊流重置")
    }

    private func cancelDialogueAgentTasks() {
        dialogueAgentTasks.values.forEach { $0.cancel() }
        dialogueAgentTasks.removeAll()
    }

    private func looksLikeAgentNoise(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"(.)(\1){7,}"#, options: .regularExpression) != nil { return true }
        if trimmed.contains("ーーー") || trimmed.contains("啊啊啊") || trimmed.contains("雜音") || trimmed.contains("噪音") {
            return true
        }
        return false
    }

    // MARK: - Lock Screen Controls（鎖屏通話控制）

    /// 鎖屏計時器（更新 Now Playing 的播放時間）
    private var nowPlayingTimer: Timer?

    /// 設定鎖屏 Now Playing 顯示 + 遠端控制按鈕
    private func setupNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        let commandCenter = MPRemoteCommandCenter.shared()

        // 顯示資訊
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "通話中 In Call",
            MPMediaItemPropertyArtist: "\(sourceLang.shortName) → \(targetLang.shortName)",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPMediaItemPropertyPlaybackDuration: 0.0  // 0 = 不顯示進度條
        ]
        center.nowPlayingInfo = info
        center.playbackState = .playing

        // 停止按鈕 → 結束通話
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.endCall() }
            return .success
        }

        // 暫停按鈕 → 也結束通話
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.endCall() }
            return .success
        }

        // 播放按鈕 → 禁用（通話中不需要）
        commandCenter.playCommand.isEnabled = false

        // 定時更新經過時間
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            var info = center.nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(self.recordingDuration)
            center.nowPlayingInfo = info
        }

        // 讓 app 成為 Now Playing 的目標
        UIApplication.shared.beginReceivingRemoteControlEvents()

        print("🔒 [LockScreen] Now Playing 已設定")
    }

    /// 清除鎖屏 Now Playing
    private func clearNowPlaying() {
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.playCommand.isEnabled = true

        UIApplication.shared.endReceivingRemoteControlEvents()
        print("🔒 [LockScreen] Now Playing 已清除")
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
        currentMicVolume = 0
        isManualInputActive = false
    }

    /// ⭐️ 結束通話（同步方法，立即更新 UI）
    @MainActor
    func endCall() {
        // ⭐️ 強制重置 isProcessing，允許用戶重新連接
        isProcessing = false
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

    /// 清除所有轉錄記錄（包括統計）
    func clearTranscripts() {
        transcripts.removeAll()
        interimTranscript = nil
        transcriptCount = 0
        wordCount = 0
    }

    /// ⭐️ 只清除對話內容（保留統計數據）
    func clearTranscriptsOnly() {
        transcripts.removeAll()
        interimTranscript = nil
        print("🗑️ [ViewModel] 對話已清除（保留統計）")
    }

    /// ⭐️ 刪除單則對話
    func deleteTranscript(id: UUID) {
        transcripts.removeAll { $0.id == id }
        print("🗑️ [ViewModel] 已刪除對話 \(id)")
    }

    /// ⭐️ 開始編輯某則對話（設定狀態，由 UI 觸發 sheet）
    func startEditing(transcript: TranscriptMessage) {
        let t0 = Date()
        editingTranscriptId = transcript.id
        editingInitialText = transcript.text
        showEditSheet = true
        print("⏱️ [startEditing] \(Int(Date().timeIntervalSince(t0)*1000))ms")
    }

    /// ⭐️ 編輯對話文字並重新翻譯
    func editTranscriptAndRetranslate(id: UUID, newText: String) {
        guard let index = transcripts.firstIndex(where: { $0.id == id }) else {
            print("⚠️ [編輯] 找不到對話 \(id)")
            return
        }
        let oldText = transcripts[index].text
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldText else { return }

        // 更新文字並清除舊翻譯
        transcripts[index].text = trimmed
        transcripts[index].translation = nil
        transcripts[index].translationSegments = nil
        print("✏️ [編輯] \"\(oldText.prefix(30))\" → \"\(trimmed.prefix(30))\"")

        // 觸發重新翻譯
        let textToTranslate = trimmed
        Task {
            await elevenLabsService.retranslateText(textToTranslate)
        }
    }

    // MARK: - Language Introduction

    /// ⭐️ 已顯示過介紹的語言對（切換語言才重新顯示）
    private var shownIntroductionPair: String?

    /// ⭐️ 從 Firestore 讀取語言介紹，插入對話列表最前面
    /// 同一語言對只顯示一次，切換語言後才會再次顯示
    @MainActor
    private func showLanguageIntroduction() async {
        let src = sourceLang.rawValue
        let tgt = targetLang.rawValue
        let pairKey = "\(src)_\(tgt)"

        // ⭐️ 同一語言對不重複顯示
        if shownIntroductionPair == pairKey {
            print("📋 [Introduction] 已顯示過: \(pairKey)，跳過")
            return
        }

        guard let intro = await IntroductionService.shared.fetchIntroduction(
            sourceLang: src, targetLang: tgt
        ) else {
            print("⚠️ [Introduction] 無介紹文字: \(pairKey)")
            return
        }

        // 來源語言介紹（右側藍色氣泡）
        let sourceMessage = TranscriptMessage(
            text: intro.sourceIntro,
            isFinal: true,
            confidence: 1.0,
            language: src,
            translation: intro.sourceIntro,
            isIntroduction: true
        )

        // 目標語言介紹（左側灰色氣泡）
        let targetMessage = TranscriptMessage(
            text: intro.targetIntro,
            isFinal: true,
            confidence: 1.0,
            language: tgt,
            translation: intro.targetIntro,
            isIntroduction: true
        )

        // 插入對話列表最前面
        transcripts.insert(contentsOf: [sourceMessage, targetMessage], at: 0)
        shownIntroductionPair = pairKey
        print("📋 [Introduction] 已顯示雙語介紹: \(pairKey)")
    }

    // MARK: - Hallucination Warning

    /// 上次顯示幻聽警告的時間（避免短時間內重複提示）
    private var lastHallucinationWarningTime: Date?

    /// ⭐️ 顯示幻聽警告（雙語提示）
    private func showHallucinationWarning(detectedLanguage: String) {
        // 防止短時間內重複提示（5 秒內只提示一次）
        if let lastTime = lastHallucinationWarningTime,
           Date().timeIntervalSince(lastTime) < 5.0 {
            return
        }
        lastHallucinationWarningTime = Date()

        let sourceWarning = hallucinationText(for: sourceLang.rawValue)
        let targetWarning = hallucinationText(for: targetLang.rawValue)

        // 來源語言提示（右側）
        let sourceMessage = TranscriptMessage(
            text: "⚠️ \(sourceWarning)",
            isFinal: true,
            confidence: 0,
            language: sourceLang.rawValue,
            translation: "⚠️ \(sourceWarning)",
            isIntroduction: true  // 複用：不顯示翻譯行，只顯示原文
        )

        // 目標語言提示（左側）
        let targetMessage = TranscriptMessage(
            text: "⚠️ \(targetWarning)",
            isFinal: true,
            confidence: 0,
            language: targetLang.rawValue,
            translation: "⚠️ \(targetWarning)",
            isIntroduction: true
        )

        transcripts.append(contentsOf: [sourceMessage, targetMessage])
        print("🚫 [幻聽警告] 已顯示雙語提示 (detected: \(detectedLanguage))")
    }

    /// 各語言的幻聽提示文字
    private func hallucinationText(for langCode: String) -> String {
        switch langCode {
        case "zh": return "語音辨識異常，請稍候再說一次"
        case "en": return "Speech recognition error. Please wait a moment and try again."
        case "ja": return "音声認識に異常が発生しました。少し待ってからもう一度話してください。"
        case "ko": return "음성 인식 오류가 발생했습니다. 잠시 후 다시 말씀해 주세요."
        case "es": return "Error de reconocimiento de voz. Espere un momento e intente de nuevo."
        case "fr": return "Erreur de reconnaissance vocale. Veuillez patienter et réessayer."
        case "de": return "Spracherkennungsfehler. Bitte warten Sie einen Moment und versuchen Sie es erneut."
        case "pt": return "Erro de reconhecimento de voz. Aguarde um momento e tente novamente."
        case "ru": return "Ошибка распознавания речи. Подождите немного и попробуйте снова."
        case "it": return "Errore di riconoscimento vocale. Attendere un momento e riprovare."
        case "vi": return "Lỗi nhận dạng giọng nói. Vui lòng đợi một chút và thử lại."
        case "th": return "เกิดข้อผิดพลาดในการรู้จำเสียง กรุณารอสักครู่แล้วลองใหม่"
        case "ar": return "خطأ في التعرف على الصوت. يرجى الانتظار لحظة والمحاولة مرة أخرى."
        case "hi": return "वाक् पहचान त्रुटि। कृपया एक क्षण प्रतीक्षा करें और पुनः प्रयास करें।"
        case "id": return "Kesalahan pengenalan suara. Harap tunggu sebentar dan coba lagi."
        case "fil": return "Error sa pagkilala ng boses. Maghintay sandali at subukan muli."
        case "ms": return "Ralat pengecaman suara. Sila tunggu sebentar dan cuba lagi."
        case "tr": return "Ses tanıma hatası. Lütfen bir an bekleyin ve tekrar deneyin."
        case "nl": return "Spraakherkenningsfout. Wacht even en probeer het opnieuw."
        default: return "Speech recognition error. Please wait and try again."
        }
    }

    // MARK: - Private Methods

    /// 開始錄音
    @MainActor
    private func startRecording() async {
        // ⭐️ 立即設置連接狀態，讓 UI 先切換（順暢體驗）
        status = .connecting
        currentMicVolume = 0
        isManualInputActive = false

        // ⭐️ 讓出主線程，讓 UI 有機會更新
        await Task.yield()

        // 編輯第一句前就可能需要鍵盤；在連線/錄音真正開始前先觸發，避免首次編輯卡住。
        KeyboardPrewarmer.prewarm()
        await Task.yield()

        // ⭐️ 檢查用戶額度（至少需要 100 額度才能開始）
        // Apple STT 免費，不需要檢查額度
        if sttProvider != .apple {
            guard AuthService.shared.hasEnoughCredits(100) else {
                let currentCredits = AuthService.shared.currentUser?.slowCredits ?? 0
                print("🚨 [ViewModel] 拒絕連線：額度不足（剩餘 \(currentCredits)）")
                status = .disconnected
                // ⭐️ 顯示額度不足對話框
                showCreditsExhaustedAlert = true
                return
            }
        }

        // 請求麥克風權限
        let granted = await audioManager.requestPermission()
        guard granted else {
            status = .error("請允許使用麥克風")
            return
        }

        print("🔌 開始連接伺服器: \(serverURL) (使用 \(sttProvider.displayName))")
        sttReconnectInProgress = false
        lastSTTReconnectAttempt = .distantPast
        resetPendingSTTEvents()
        agentAudioReplayBuffer.clear()

        // ⭐️ 根據選擇的 STT 提供商連接
        if isEconomyMode {
            // 經濟模式：使用單語言 Apple STT
            print("🌿 [經濟模式] 使用單語言識別: \(economyActiveLanguage.shortName)")
            appleSTTService.connectSingleLanguage(
                serverURL: serverURL,
                sourceLang: sourceLang,
                targetLang: targetLang,
                activeLanguage: economyActiveLanguage
            )
        } else {
            // 一般模式：使用選擇的 STT 提供商
            currentSTTService.connect(
                serverURL: serverURL,
                sourceLang: sourceLang,
                targetLang: targetLang
            )
        }

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
            setupNowPlaying()

            // ⭐️ 啟動前台閒置計時器（10 分鐘無轉錄 → 自動斷線）
            startIdleTimer()
            startSTTConnectionWatchdog()

            // ⭐️ 顯示雙語介紹提示（從 Firestore 讀取）
            Task {
                await showLanguageIntroduction()
            }

            // ⭐️ 預熱 TTS 引擎（避免第一次播放卡頓）
            if ttsProvider == .apple {
                // 預熱來源和目標語言（preWarm 內部會跳過已預熱的語言）
                appleTTSService.preWarmLanguages([
                    sourceLang.azureLocale,
                    targetLang.azureLocale
                ])
            } else {
                ttsService.preConnect()
            }

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
        currentMicVolume = 0
        isManualInputActive = false

        stopDurationTimer()
        clearNowPlaying()

        // ⭐️ 停止閒置計時器
        idleTimer?.invalidate()
        idleTimer = nil
        stopSTTConnectionWatchdog()
        sttReconnectInProgress = false
        lastSTTReconnectAttempt = .distantPast
        resetPendingSTTEvents()
        cancelDialogueAgentTasks()
        agentAudioReplayBuffer.clear()
        isPausedForBackground = false
        backgroundEntryTime = nil

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

        // 清除 interim
        interimTranscript = nil

        // ⭐️ 停止閒置翻譯檢查計時器
        translationIdleTimer?.invalidate()
        translationIdleTimer = nil

        // ⭐️ 停止錄音時，立即播放待播放的 TTS（對話框已確定結束）
        if pendingTTS != nil {
            print("🎵 [TTS] 停止錄音，對話框確定結束，立即播放待播放內容")
            flushPendingTTS()
        }
        lastFinalText = ""  // ⭐️ 重置最後 final 文本

        // ⭐️ 清理已播放記錄（下一次通話重新開始）
        playedTranslations.removeAll()
        agentTTSProgressByTurn.removeAll()
        print("🧹 [TTS] 停止錄音，清理已播放記錄")

        // ⭐️ 重置 Streaming TTS 狀態
        resetStreamingTTSState()

        // ⭐️ 結束 Session（保存對話記錄）
        // 注意：扣款已改為即時扣款（在 BillingService 中處理），這裡不再扣款
        Task {
            // 結束 Session 並獲取用量統計（僅用於記錄）
            let usage = await sessionService.endSession()
            sessionService.invalidateHistoryCache()
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

    // MARK: - ⭐️ 經濟模式語言切換

    /// 經濟模式下切換語言（雙麥克風按鈕用）
    @MainActor
    func switchEconomyLanguage(to language: Language) {
        guard isEconomyMode else {
            print("⚠️ [經濟模式] 非經濟模式，無法切換語言")
            return
        }

        guard isRecording else {
            print("⚠️ [經濟模式] 未在通話中，無法切換語言")
            return
        }

        guard language != economyActiveLanguage else {
            print("ℹ️ [經濟模式] 已經是 \(language.shortName)")
            return
        }

        print("🔄 [經濟模式] 切換語言: \(economyActiveLanguage.shortName) → \(language.shortName)")

        // 調用 Apple STT 的語言切換方法
        let switchTime = appleSTTService.switchLanguage(to: language)

        // 更新狀態
        economyActiveLanguage = language
        lastLanguageSwitchTime = switchTime

        print("⏱️ [經濟模式] 語言切換耗時: \(String(format: "%.0f", switchTime))ms")
    }

    /// 經濟模式下是否為當前活動語言
    func isEconomyActiveLanguage(_ language: Language) -> Bool {
        guard isEconomyMode else { return false }
        return language == economyActiveLanguage
    }

    // MARK: - ⭐️ 經濟模式 PTT 錄音（按住錄音，放開比較兩種語言）

    /// 開始經濟模式錄音（按住麥克風時調用）
    func startEconomyRecording() {
        guard isEconomyMode, isRecording else {
            print("⚠️ [經濟模式] 未在通話中或非經濟模式")
            return
        }

        print("🎙️ [經濟模式] 開始錄音...")
        isManualInputActive = true

        // 清空音頻緩衝區，準備接收新的錄音
        appleSTTService.clearAudioBuffer()

        // 開始發送音頻到 STT
        audioManager.startSending()
    }

    /// 停止經濟模式錄音並觸發雙語言比較（放開麥克風時調用）
    func stopEconomyRecordingAndCompare() {
        guard isEconomyMode, isRecording else {
            print("⚠️ [經濟模式] 未在通話中或非經濟模式")
            return
        }

        print("🛑 [經濟模式] 停止錄音，開始雙語言比較...")
        isManualInputActive = false

        // 停止發送音頻
        audioManager.stopSending()

        // 觸發雙語言比較（使用緩衝區中的音頻）
        appleSTTService.startDualLanguageComparison()
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
            // VAD 模式：同步 VAD 旗標 + 開始持續監聽
            isManualInputActive = false
            audioManager.isVADEnabled = isLocalVADEnabled
            if isRecording {
                audioManager.startSending()
            }
        } else {
            // PTT 模式：關閉 VAD + 停止發送，等待按住
            isManualInputActive = false
            audioManager.isVADEnabled = false
            audioManager.stopSending()
        }
    }

    // MARK: - Push-to-Talk Methods

    /// 開始說話（按下按鈕時調用，僅 PTT 模式有效）
    func startTalking() {
        guard isRecording else { return }
        guard inputMode == .ptt else { return }  // VAD 模式不需要手動控制
        isManualInputActive = true
        audioManager.startSending()
    }

    /// 停止說話（放開按鈕時調用，僅 PTT 模式有效）
    func stopTalking() {
        guard inputMode == .ptt else { return }  // VAD 模式不需要手動控制
        isManualInputActive = false
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
                // ⭐️ 檢查是否正在錄音，避免停止後的殘留音頻被處理
                guard let self, self.isRecording else { return }
                self.processOutgoingAudioForSTT(data)
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
                guard let self, self.sttProvider == .chirp3 else { return }
                print("❌ [Chirp3] 錯誤: \(errorMessage)")
                if self.isRecording {
                    self.attemptSTTReconnectIfNeeded(reason: "Chirp3 錯誤: \(errorMessage)")
                } else {
                    self.status = .error(errorMessage)
                }
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
                guard let self, self.sttProvider == .elevenLabs else { return }
                print("❌ [ElevenLabs] 錯誤: \(errorMessage)")
                if self.isRecording {
                    self.attemptSTTReconnectIfNeeded(reason: "ElevenLabs 錯誤: \(errorMessage)")
                } else {
                    self.status = .error(errorMessage)
                }
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱 ElevenLabs 幻聽通知（腳本驗證失敗）
        elevenLabsService.hallucinationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detectedLang in
                guard let self, self.sttProvider == .elevenLabs else { return }
                self.showHallucinationWarning(detectedLanguage: detectedLang)
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
                guard let self, self.sttProvider == .apple else { return }
                print("❌ [Apple STT] 錯誤: \(errorMessage)")
                self.status = .error(errorMessage)
                // ⭐️ 連接斷開時自動停止錄音
                if self.isRecording {
                    print("⚠️ [Apple STT] 錯誤，自動停止錄音")
                    self.stopRecording()
                }
            }
            .store(in: &cancellables)

        // ⭐️ 設置自動語言切換回調（同步 UI）
        appleSTTService.onLanguageSwitched = { [weak self] language in
            guard let self, self.isEconomyMode else { return }
            if self.economyActiveLanguage != language {
                print("🔄 [經濟模式] UI 同步語言: \(self.economyActiveLanguage.shortName) → \(language.shortName)")
                self.economyActiveLanguage = language
            }
        }

        // ⭐️ 比較顯示模式：接收兩種語言的比較結果（舊版，僅用於調試）
        appleSTTService.onComparisonResults = { [weak self] results in
            guard let self, self.isEconomyMode, self.isComparisonDisplayMode else { return }

            print("🔬 [比較模式] 收到 \(results.count) 個比較結果")

            // 創建兩個對話框，顯示兩種語言的結果
            for result in results {
                let confidenceStr = String(format: "%.0f%%", result.confidence * 100)
                let langLabel = "[\(result.lang.shortName)] "

                let transcript = TranscriptMessage(
                    text: langLabel + result.text,
                    isFinal: true,
                    confidence: Double(result.confidence),
                    language: result.lang.rawValue,
                    translation: "信心度: \(confidenceStr)"  // 用翻譯欄位顯示信心度
                )

                // 添加到對話列表
                self.transcripts.append(transcript)
                self.transcriptCount += 1
            }
        }

        // ⭐️ 經濟模式 PTT：接收最佳比較結果（自動選擇信心最高的語言）
        appleSTTService.onBestComparisonResult = { [weak self] bestLang, text, confidence in
            guard let self, self.isEconomyMode else { return }

            print("🏆 [經濟模式 PTT] 選中: \(bestLang.shortName) (信心: \(String(format: "%.0f%%", confidence * 100)))")
            print("   文本: \"\(text.prefix(40))...\"")

            // ⭐️ 同步語言到 UI（下次錄音預設用這個語言）
            if self.economyActiveLanguage != bestLang {
                print("🔄 [經濟模式] 切換預設語言: \(self.economyActiveLanguage.shortName) → \(bestLang.shortName)")
                self.economyActiveLanguage = bestLang
            }

            // ⭐️ 注意：transcript 和翻譯已由 AppleSTTService 處理
            // - _transcriptSubject.send() 發送到 UI
            // - translateText() 觸發翻譯 API
            // - 翻譯結果會通過 translationPublisher 發送，觸發 TTS
        }

        // ⭐️ TTS 播放完成回調（播放隊列中的下一個）
        audioManager.onTTSPlaybackFinished = { [weak self] in
            self?.processNextTTS()
        }

        // ⭐️ Apple TTS 播放完成回調
        appleTTSService.onPlaybackFinished = { [weak self] in
            self?.isAppleTTSPlaying = false  // ⭐️ 更新狀態（觸發 UI 更新）
            self?.appleTTSCurrentText = nil  // ⭐️ 清除當前播放文本
            self?.processNextTTS()
        }

        // ⭐️ PTT 結束語句回調（發送結束信號）
        audioManager.onEndUtterance = { [weak self] in
            DispatchQueue.main.async {
                Task { @MainActor in
                    self?.handleEndUtterance()
                }
            }
        }

        // ⭐️ 訂閱即時麥克風音量（只給設定頁音量條；通話聲波在獨立 View 內訂閱）
        audioManager.volumePublisher
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                guard let self = self else { return }
                // ⭐️ 只在設定頁面開啟時才更新 UI 變數，避免影響通話中的 STT 送音
                if self.isVolumeMonitoringEnabled {
                    self.currentMicVolume = volume
                }
            }
            .store(in: &cancellables)

        // ⭐️ 訂閱本地 VAD 狀態變化，並通知 STT 服務（防幻聽過濾）
        audioManager.onVADStateChanged = { [weak self] state in
            guard let self else { return }
            self.localVADState = state
            // 通知 ElevenLabs 服務 VAD 是否已暫停（靜音 ≥ 2s，停止發送音訊）
            // 只有 paused 狀態會觸發幻聽過濾，silent 短暫停頓不會過濾
            self.elevenLabsService.updateClientVADPaused(state == .paused)
        }

        // ⭐️ 訂閱額度耗盡回調（自動停止錄音）
        BillingService.shared.onCreditsExhausted = { [weak self] in
            guard let self = self else { return }
            print("🚨 [ViewModel] 額度耗盡，自動停止錄音")
            // 先停止錄音
            Task { @MainActor in
                await self.toggleRecording()
                // 停止後顯示對話框
                self.showCreditsExhaustedAlert = true
            }
        }
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

    /// ⭐️ 判斷新文本是否是舊文本的延續（用於合併對話框）
    /// 返回 true 表示應該合併，false 表示應該創建新對話框
    private func shouldMergeTexts(newText: String, lastText: String) -> Bool {
        guard !lastText.isEmpty else { return false }

        let newTextLower = newText.lowercased()
        let lastTextLower = lastText.lowercased()

        // ⭐️ 0. 完全相同的文本（自動提升 + VAD commit 可能發送相同文本）
        if newTextLower == lastTextLower {
            return true
        }
        // 1. 新句子包含舊句子（完全包含）
        if newTextLower.contains(lastTextLower) && newText.count > lastText.count {
            return true
        }
        // ⭐️ 1.5 舊句子包含新句子（反向包含，新文本是舊文本的子集）
        // 例如：自動提升發送了較長文本，VAD commit 發送了較短版本
        if lastTextLower.contains(newTextLower) && lastText.count > newText.count {
            return true
        }
        // 2. 新句子以舊句子為前綴（忽略大小寫）
        if newTextLower.hasPrefix(lastTextLower) && newText.count > lastText.count {
            return true
        }
        // 3. 高度重疊檢測（忽略大小寫）
        if lastText.count >= 3 {
            var commonPrefixLength = 0
            let newChars = Array(newTextLower)
            let lastChars = Array(lastTextLower)
            for i in 0..<min(newChars.count, lastChars.count) {
                if newChars[i] == lastChars[i] {
                    commonPrefixLength += 1
                } else {
                    break
                }
            }

            // ⭐️ 用較長文本為分母計算重疊率，避免短文本輕易觸發合併
            let maxLength = max(newText.count, lastText.count)
            let overlapRatio = Float(commonPrefixLength) / Float(maxLength)
            if overlapRatio >= 0.5 && commonPrefixLength >= 3 {
                return true
            }
        }

        return false
    }

    /// 判斷某次翻譯使用的原文是否完整覆蓋目前 final 原文。
    /// 這裡會忽略標點和空白，但保留數字與文字；例如最後的「30元」不能被 90% 覆蓋率放過。
    private func translationSourceCoversFinalText(sourceText: String, finalText: String) -> Bool {
        let normalizedSource = normalizeTextForComparison(sourceText)
        let normalizedFinal = normalizeTextForComparison(finalText)
        guard !normalizedFinal.isEmpty else { return true }
        guard !normalizedSource.isEmpty else { return false }
        return normalizedSource == normalizedFinal
    }

    private func translationSegmentsCoverFinalText(_ segments: [TranslationSegment]?, finalText: String) -> Bool {
        guard let segments, !segments.isEmpty else { return false }
        let combinedOriginal = segments.map { $0.original }.joined()
        return translationSourceCoversFinalText(sourceText: combinedOriginal, finalText: finalText)
    }

    private func preservedTranslationCoversFinalText(
        sourceText: String?,
        segments: [TranslationSegment]?,
        finalText: String
    ) -> Bool {
        if let segments, !segments.isEmpty {
            return translationSegmentsCoverFinalText(segments, finalText: finalText)
        }
        guard let sourceText else { return false }
        return translationSourceCoversFinalText(sourceText: sourceText, finalText: finalText)
    }

    private func requestFullRetranslationIfNeeded(for text: String, reason: String) {
        let normalized = normalizeTextForComparison(text)
        guard !normalized.isEmpty else { return }

        if pendingFullRetranslationTexts.contains(normalized) {
            print("⏳ [完整補翻] 已在處理中，跳過重複請求: \(reason)")
            return
        }

        pendingFullRetranslationTexts.insert(normalized)
        print("🔄 [完整補翻] \(reason): \"\(text.prefix(40))...\"")

        Task { [weak self] in
            guard let self else { return }
            await self.elevenLabsService.retranslateText(text)
            await MainActor.run {
                _ = self.pendingFullRetranslationTexts.remove(normalized)
            }
        }
    }

    /// 處理轉錄結果
    private func handleTranscript(_ transcript: TranscriptMessage) {
        // ⭐️ 記錄收到 transcript 的時間（用於 TTS 播放前檢查）
        lastTranscriptTime = Date()
        // ⭐️ 重置閒置計時器（有活動 = 不閒置）
        resetIdleTimer()

        if transcript.isFinal {
            // 最終結果：添加到列表末尾（最新的在下面）
            var finalTranscript = transcript

            // ⭐️ 修復：合併時保留被移除 transcript 的翻譯
            var removedTranslation: String? = nil
            var removedTranslationSegments: [TranslationSegment]? = nil
            var lastTranscriptTextBeforeMerge: String? = nil

            // ⭐️ 檢查新句子是否是上一句的「延續」（ElevenLabs 分段問題）
            // 例如：
            // - "yeah actually" → "Yeah, actually I'm a student"
            // - "我早餐吃了兩" → "我早餐吃了兩個蛋糕"
            // 這種情況下應該「替換」上一句，保持同一個對話框
            if let lastTranscript = transcripts.last {
                let newText = transcript.text
                let lastText = lastTranscript.text

                if shouldMergeTexts(newText: newText, lastText: lastText) {
                    // ⭐️ 防止短文本取代長文本（保留較長的版本）
                    if newText.count < lastText.count {
                        print("🔄 [Final 合併] 新文本較短，保留舊文本，更新翻譯")
                        print("   保留: \"\(lastText.prefix(35))...\" (\(lastText.count)字)")
                        print("   跳過: \"\(newText.prefix(35))...\" (\(newText.count)字)")
                        // 只更新翻譯（如果新的更好）
                        if let newTranslation = transcript.translation, !newTranslation.isEmpty {
                            if lastTranscript.translation == nil || lastTranscript.translation?.isEmpty == true {
                                transcripts[transcripts.count - 1].translation = newTranslation
                                transcripts[transcripts.count - 1].translationSegments = transcript.translationSegments
                                print("   ✅ 更新翻譯: \"\(newTranslation.prefix(30))...\"")
                            }
                        }
                        interimTranscript = nil
                        lastFinalText = lastText
                        return
                    }

                    print("🔄 [Final 合併] 新句子是上一句的延續")
                    print("   舊: \"\(lastText.prefix(30))...\"")
                    print("   新: \"\(newText.prefix(40))...\"")

                    // ⭐️ 取消舊對話的 TTS（只播放合併後對話的翻譯）
                    cancelTTSForMergedDialog(oldText: lastText)

                    // ⭐️ 修復：在移除前保留翻譯（避免翻譯丟失）
                    removedTranslation = lastTranscript.translation
                    removedTranslationSegments = lastTranscript.translationSegments
                    lastTranscriptTextBeforeMerge = lastTranscript.text

                    // ⭐️ 替換而不是刪除：更新最後一個 transcript
                    transcripts.removeLast()
                }
            }

            // ⭐️ 記錄最後一個 final 的文本（用於判斷新句子）
            lastFinalText = transcript.text

            // ⭐️ TTS 保障機制：從 interim 或被移除的 transcript 保留翻譯並觸發 TTS
            // 問題：翻譯可能在 transcript 還是 interim 時就到了，此時 matchedFinal=false 不會觸發 TTS
            // 當 interim 變成 final 時，翻譯不會再發送，導致 TTS 遺漏
            // 解決：在這裡檢查並補播

            // ⭐️ 修復：優先使用 transcript 自帶的翻譯（分句場景更準確），
            // 其次使用 interim 翻譯，最後使用被移除 transcript 的翻譯
            let preservedTranslation: String?
            let preservedTranslationSegments: [TranslationSegment]?
            let preservedTranslationSourceText: String?

            if let ownTranslation = transcript.translation, !ownTranslation.isEmpty {
                // ⭐️ transcript 自帶翻譯（從 ElevenLabs 分句場景帶過來的）最精確
                preservedTranslation = ownTranslation
                preservedTranslationSegments = transcript.translationSegments
                preservedTranslationSourceText = transcript.text
            } else if let interimTranslation = interimTranscript?.translation, !interimTranslation.isEmpty {
                preservedTranslation = interimTranslation
                preservedTranslationSegments = interimTranscript?.translationSegments
                preservedTranslationSourceText = interimTranscript?.text
            } else if let removed = removedTranslation, !removed.isEmpty {
                preservedTranslation = removed
                preservedTranslationSegments = removedTranslationSegments
                preservedTranslationSourceText = lastTranscriptTextBeforeMerge
            } else {
                preservedTranslation = transcript.translation
                preservedTranslationSegments = transcript.translationSegments
                preservedTranslationSourceText = transcript.text
            }

            var finalNeedsFullRetranslation = false

            if let translation = preservedTranslation, !translation.isEmpty {
                finalTranscript.translation = translation
                finalTranscript.translationSegments = preservedTranslationSegments
                print("✅ [Final] 保留翻譯: \"\(translation.prefix(30))...\"")

                if !preservedTranslationCoversFinalText(
                    sourceText: preservedTranslationSourceText,
                    segments: preservedTranslationSegments,
                    finalText: finalTranscript.text
                ) {
                    finalNeedsFullRetranslation = true
                    print("⚠️ [Final] 保留翻譯來源未覆蓋完整 final，稍後補翻完整句")
                    print("   翻譯來源: \"\((preservedTranslationSourceText ?? "segments").prefix(35))...\"")
                    print("   final: \"\(finalTranscript.text.prefix(45))...\"")
                }

                if finalNeedsFullRetranslation {
                    print("⏸️ [TTS 保障] 暫不播放舊翻譯，等待完整補翻")
                } else {
                    // ⭐️ TTS 保障：檢查這個翻譯是否已經在等待播放
                    let normalizedTranslation = normalizeTextForComparison(translation)
                    let isAlreadyPending = pendingTTS != nil && normalizeTextForComparison(pendingTTS!.text) == normalizedTranslation
                    let isAlreadyQueued = ttsQueue.contains(where: { normalizeTextForComparison($0.text) == normalizedTranslation })
                    let isAlreadyPlayed = playedTranslations.contains(normalizedTranslation)

                    if !isAlreadyPending && !isAlreadyQueued && !isAlreadyPlayed {
                        // ⭐️ 翻譯還沒觸發過 TTS，現在補播
                        let detectedLanguage = interimTranscript?.language ?? finalTranscript.language
                        if shouldPlayTTSForMode(detectedLanguage: detectedLanguage) {
                            let targetLangCode = getTargetLanguageCode(detectedLanguage: detectedLanguage)
                            print("🔧 [TTS 保障] 補播翻譯: \"\(translation.prefix(25))...\"")
                            enqueueTTS(text: translation, languageCode: targetLangCode)
                        }
                    } else {
                        print("ℹ️ [TTS] 翻譯已在處理中: pending=\(isAlreadyPending), queued=\(isAlreadyQueued), played=\(isAlreadyPlayed)")
                    }
                }
            }

            transcripts.append(finalTranscript)
            interimTranscript = nil
            updateStats()

            // ⭐️ 保存對話到 Session（判斷是否為來源語言）
            let isSource = isSourceLanguage(detectedLanguage: finalTranscript.language)
            sessionService.addConversation(finalTranscript, isSource: isSource)

            // ⭐️ 交給 Google ADK Agent 做跨句合併、混合語言拆分、TTS 計畫與音訊重置建議
            scheduleDialogueAgentProcessing(for: finalTranscript)

            // Final 到了 → 如果沒有完整翻譯，對完整文字發翻譯
            // ElevenLabs 側已在 VAD commit 時觸發翻譯，這裡只補漏
            if finalTranscript.translation?.isEmpty != false {
                let finalText = finalTranscript.text
                requestFullRetranslationIfNeeded(for: finalText, reason: "final 無翻譯")
            } else if finalNeedsFullRetranslation {
                requestFullRetranslationIfNeeded(for: finalTranscript.text, reason: "final 翻譯未覆蓋最後文字")
            }
        } else {
            // ⭐️ 中間結果：檢查是否為新的語句
            // 注意：ElevenLabs 使用 VAD 自動 commit，不需要 Pseudo-Final 機制
            // Chirp3 可能需要，因為有時 final 結果會丟失

            // ⭐️ 關鍵改進：預先檢查是否能與 transcripts.last 合併
            // 避免新泡泡閃現後又合併消失的問題
            if let lastTranscript = transcripts.last,
               shouldMergeTexts(newText: transcript.text, lastText: lastTranscript.text) {

                // ⭐️ 使用較長的文本作為合併結果
                let mergedText = transcript.text.count >= lastTranscript.text.count ? transcript.text : lastTranscript.text

                // ⭐️ 直接更新 transcripts.last，不創建新的 interimTranscript
                print("🔄 [Interim→合併] 直接更新上一個對話框")
                print("   舊: \"\(lastTranscript.text.prefix(30))...\"")
                print("   新: \"\(transcript.text.prefix(40))...\"")
                print("   合併: \"\(mergedText.prefix(40))...\"")

                // 取消舊對話的 TTS
                cancelTTSForMergedDialog(oldText: lastTranscript.text)

                // ⭐️ 修復：合併翻譯時優先使用 interimTranscript 的翻譯（可能更新）
                // 避免 interimTranscript 有翻譯但 lastTranscript 沒有的情況導致翻譯丟失
                let mergedTranslation: String?
                let mergedTranslationSegments: [TranslationSegment]?

                if let interimTrans = interimTranscript?.translation, !interimTrans.isEmpty {
                    // 優先使用 interim 的翻譯（通常更新）
                    mergedTranslation = interimTrans
                    mergedTranslationSegments = interimTranscript?.translationSegments
                } else {
                    // 否則保留 lastTranscript 的翻譯
                    mergedTranslation = lastTranscript.translation
                    mergedTranslationSegments = lastTranscript.translationSegments
                }

                // ⭐️ 創建新的 TranscriptMessage（保留原有 ID 和翻譯，使用較長文本）
                let updatedTranscript = TranscriptMessage(
                    id: lastTranscript.id,  // 保留原有 ID（避免 UI 閃爍）
                    text: mergedText,  // ⭐️ 使用較長的文本
                    isFinal: lastTranscript.isFinal,  // 保持 final 狀態
                    confidence: transcript.confidence,  // 使用新的信心度
                    language: transcript.language ?? lastTranscript.language,  // 優先使用新語言
                    converted: lastTranscript.converted,
                    originalText: lastTranscript.originalText,
                    speakerTag: lastTranscript.speakerTag,
                    timestamp: lastTranscript.timestamp,  // 保留原有時間戳
                    translation: mergedTranslation,  // ⭐️ 使用合併後的翻譯
                    translationSegments: mergedTranslationSegments
                )
                transcripts[transcripts.count - 1] = updatedTranscript

                // ⭐️ 記錄為最後的 final 文本（這樣後續 interim 能正確判斷）
                lastFinalText = mergedText

                // ⭐️ 清除 interimTranscript（避免顯示重複泡泡）
                interimTranscript = nil
                return
            }

            // ⭐️ 檢測是否為新句子開始（與上一個 final 不同）
            // 如果是新句子，立即播放上一個對話框的 TTS
            if !lastFinalText.isEmpty {
                let newText = transcript.text.lowercased().replacingOccurrences(of: " ", with: "")
                let lastText = lastFinalText.lowercased().replacingOccurrences(of: " ", with: "")

                // 新句子的判斷：新 interim 不是上一個 final 的延續
                let isNewSentence = !newText.hasPrefix(lastText) && !lastText.hasPrefix(newText)

                if isNewSentence && pendingTTS != nil {
                    print("🆕 [TTS] 檢測到新句子開始，立即播放上一句")
                    print("   上一句: \"\(lastFinalText.prefix(25))...\"")
                    print("   新 interim: \"\(transcript.text.prefix(25))...\"")
                    flushPendingTTS()
                }
            }

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

            // ⭐️ 更新 interim，但保留舊的 ID 和翻譯（避免 UI 閃爍和翻譯消失）
            if let oldInterim = interimTranscript {
                // ⭐️ 檢查新 interim 是否是舊 interim 的延續
                if shouldMergeTexts(newText: transcript.text, lastText: oldInterim.text) {
                    // 是延續：保留舊 ID，只更新文本和其他屬性
                    print("🔄 [Interim→Interim 合併] 保留舊 ID，更新內容")
                    print("   舊: \"\(oldInterim.text.prefix(30))...\"")
                    print("   新: \"\(transcript.text.prefix(40))...\"")

                    interimTranscript = TranscriptMessage(
                        id: oldInterim.id,  // ⭐️ 保留舊 ID，避免 UI 閃爍
                        text: transcript.text,
                        isFinal: false,
                        confidence: transcript.confidence,
                        language: transcript.language ?? oldInterim.language,
                        converted: transcript.converted,
                        originalText: transcript.originalText,
                        speakerTag: transcript.speakerTag,
                        timestamp: oldInterim.timestamp,  // 保留舊時間戳
                        translation: oldInterim.translation,  // 保留舊翻譯
                        translationSegments: oldInterim.translationSegments
                    )
                } else {
                    // 是新句子：使用新的 transcript（新 ID）
                    // ⭐️ 修復：為避免翻譯閃爍，在設置之前就構建好完整的對象
                    // 不要分兩步（先設置 transcript，再設置 translation），這會導致中間狀態
                    if let oldTranslation = oldInterim.translation, !oldTranslation.isEmpty {
                        // 有舊翻譯：創建新對象時就包含翻譯（避免閃爍）
                        interimTranscript = TranscriptMessage(
                            id: transcript.id,
                            text: transcript.text,
                            isFinal: transcript.isFinal,
                            confidence: transcript.confidence,
                            language: transcript.language,
                            converted: transcript.converted,
                            originalText: transcript.originalText,
                            speakerTag: transcript.speakerTag,
                            timestamp: transcript.timestamp,
                            translation: oldTranslation,  // ⭐️ 保留舊翻譯
                            translationSegments: oldInterim.translationSegments
                        )
                    } else {
                        // 沒有舊翻譯：直接設置
                        interimTranscript = transcript
                    }
                }
            } else {
                // 沒有舊 interim，直接設置
                interimTranscript = transcript
            }
        }

        // ⭐️ 每次收到新 transcript（final 或 interim），重置閒置翻譯計時器
        // 5 秒沒有新 STT 文字 → 掃描未翻譯的對話並重試
        resetTranslationIdleTimer()
    }

    /// 處理翻譯結果
    /// ⭐️ 關鍵改進：防止跨語言錯配
    /// 問題：當用戶說了兩句不同語言（如先中文後英文），
    ///       翻譯結果（英文）可能會錯配到第二句（也是英文）
    /// 解決：模糊匹配時檢查語言是否一致，只匹配同語言的 transcript
    private func handleTranslation(sourceText: String, translatedText: String) {
        // 找到對應的轉錄並添加翻譯
        var detectedLanguage: String? = nil
        var matchedFinal = false  // ⭐️ 追蹤是否匹配到 final

        // ⭐️ DEBUG: 打印匹配信息
        print("🔍 [翻譯匹配] sourceText: \"\(sourceText.prefix(50))\"")
        print("🔍 [翻譯匹配] translatedText: \"\(translatedText.prefix(50))\"")
        print("🔍 [翻譯匹配] transcripts 數量: \(transcripts.count)")

        // ⭐️ 檢測 sourceText 的語言（用於防止跨語言錯配）
        let sourceTextLang = detectLanguageFromText(sourceText)
        print("🔍 [翻譯匹配] sourceText 語言: \(sourceTextLang)")

        // ⭐️ 先嘗試精確匹配（最可靠）
        if let index = transcripts.firstIndex(where: { $0.text == sourceText }) {
            // 精確匹配到 final 結果 → 無條件更新翻譯
            detectedLanguage = transcripts[index].language
            transcripts[index].translation = translatedText
            matchedFinal = true
            print("✅ [翻譯匹配] 精確匹配到 transcripts[\(index)]")
        }
        // ⭐️ 模糊匹配：只在 transcript 是 sourceText 的前綴時匹配
        // sourceText.hasPrefix(transcript.text) → sourceText 較長，翻譯可能包含多句 → 不安全，跳過
        // transcript.text.hasPrefix(sourceText) → sourceText 較短，翻譯只覆蓋前半段
        //   → 只在 transcript 還沒翻譯時才更新（避免用不完整翻譯覆蓋完整翻譯）
        else if let index = transcripts.firstIndex(where: { transcript in
            // ⭐️ 只允許 transcript.text.hasPrefix(sourceText)（sourceText 是 transcript 的前綴）
            let textMatch = transcript.text.hasPrefix(sourceText) && sourceText != transcript.text
            guard textMatch else { return false }

            if let transcriptLang = transcript.language {
                let transcriptLangBase = transcriptLang.split(separator: "-").first.map(String.init) ?? transcriptLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                if transcriptLangBase != sourceTextLangBase {
                    return false
                }
            }
            return true
        }) {
            detectedLanguage = transcripts[index].language
            let finalText = transcripts[index].text
            let coversFullFinal = translationSourceCoversFinalText(sourceText: sourceText, finalText: finalText)

            guard coversFullFinal else {
                print("⏭️ [翻譯匹配] 舊 interim 翻譯只覆蓋 final 前段，拒絕套用")
                print("   sourceText: \"\(sourceText.prefix(40))...\"")
                print("   finalText: \"\(finalText.prefix(50))...\"")
                requestFullRetranslationIfNeeded(for: finalText, reason: "收到前段翻譯但 final 已變長")
                return
            }

            // ⭐️ 模糊匹配時的覆蓋策略：
            // 只允許已覆蓋完整 final 的翻譯更新，避免最後幾個字（如「30元」）被舊翻譯吃掉
            let hasExisting = transcripts[index].translation != nil && !transcripts[index].translation!.isEmpty
            if !hasExisting {
                transcripts[index].translation = translatedText
                print("✅ [翻譯匹配] 模糊匹配到 transcripts[\(index)]（完整覆蓋，填入）")
            } else {
                transcripts[index].translation = translatedText
                print("✅ [翻譯匹配] 模糊匹配到 transcripts[\(index)]（完整覆蓋，更新翻譯）")
            }
            matchedFinal = true
        }
        // ⭐️ 只有當 sourceText 和 interimTranscript 匹配時才更新 interim
        // ⭐️ 同樣加入語言檢查
        else if let interim = interimTranscript {
            // ⭐️ 修復跨句污染：移除 sourceText.hasPrefix(interim.text) 檢查
            // 舊邏輯允許「長的舊 sourceText」匹配「短的新 interim」，導致上句翻譯出現在下句
            // 例如: sourceText="我早餐吃了兩個蛋糕" 會匹配新 interim="我早餐"
            // 只保留: 精確匹配 + interim 是 sourceText 的延伸（正常的 interim 成長）
            let textMatch = interim.text == sourceText ||
                           interim.text.hasPrefix(sourceText)

            // ⭐️ 語言檢查
            var langMatch = true
            if let interimLang = interim.language {
                let interimLangBase = interimLang.split(separator: "-").first.map(String.init) ?? interimLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                langMatch = interimLangBase == sourceTextLangBase
            }

            if textMatch && langMatch {
                // ⭐️ 連續說話時 sourceText 幾乎一定比 interim.text 短（因為用戶持續說話），
                // 所以不應阻擋較短 sourceText 的翻譯回調。任何有效翻譯都比空白好。
                // 翻譯 API 是序列化的（pendingTranslateText 排隊機制），所以翻譯結果
                // 會按時間順序到達，不會出現舊結果覆蓋新結果的情況。
                interimTranscript?.translation = translatedText
                detectedLanguage = interim.language
                matchedFinal = false  // ⭐️ 匹配到 interim，不是 final
                print("🔄 [翻譯] 更新 interim 翻譯: src=\(sourceText.count)字, interim=\(interim.text.count)字, 「\(translatedText.prefix(30))...」")
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

        // ⭐️ 只在 Final 時播放 TTS
        // 使用 matchedFinal 來判斷，而不是比較 interimTranscript
        if matchedFinal {
            // 檢查 TTS 播放模式
            guard shouldPlayTTSForMode(detectedLanguage: detectedLanguage) else {
                print("🔇 [TTS] 播放模式不允許，跳過")
                return
            }

            // 判斷翻譯的目標語言
            let targetLangCode = getTargetLanguageCode(detectedLanguage: detectedLanguage)

            // 加入 TTS 播放隊列（等待對話框穩定）
            enqueueTTS(text: translatedText, languageCode: targetLangCode)
            print("🎵 [TTS] Final 翻譯，加入待播放: \"\(translatedText.prefix(30))...\"")
        } else {
            print("⏳ [TTS] interim 翻譯，不觸發 TTS")
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

    // MARK: - 閒置翻譯檢查

    /// ⭐️ 重置閒置翻譯計時器（每次收到新 transcript 時呼叫）
    /// STT 無新文字 5 秒後，掃描最近的對話，對缺翻譯的觸發重試
    private func resetTranslationIdleTimer() {
        translationIdleTimer?.invalidate()
        translationIdleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retryMissingTranslations()
            }
        }
    }

    /// ⭐️ 安全網：5 秒沒新 STT → 掃描完全沒翻譯的對話
    /// 正常情況下不需要（final 到來時已經觸發翻譯），只處理極端邊界情況
    private func retryMissingTranslations() {
        guard isRecording else { return }
        // 只看最後一筆
        if let last = transcripts.last {
            let missingTranslation = last.translation?.isEmpty != false
            let incompleteSegments = last.translationSegments != nil &&
                !translationSegmentsCoverFinalText(last.translationSegments, finalText: last.text)

            guard missingTranslation || incompleteSegments else { return }

            print("🔄 [閒置檢查] 最後一句需要補翻: \"\(last.text.prefix(40))...\"")
            requestFullRetranslationIfNeeded(
                for: last.text,
                reason: incompleteSegments ? "閒置檢查發現分句未覆蓋完整 final" : "閒置檢查發現最後一句無翻譯"
            )
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
            guard translationSegmentsCoverFinalText(segments, finalText: sourceText) else {
                print("⏭️ [分句翻譯] 精確 sourceText 但分句原文未覆蓋完整 final，改補翻完整句")
                requestFullRetranslationIfNeeded(for: sourceText, reason: "分句原文缺少 final 尾段")
                return
            }

            let existingTranslation = transcripts[index].translation
            if existingTranslation == nil || existingTranslation?.isEmpty == true {
                shouldPlayTTS = true
            }
            detectedLanguage = transcripts[index].language
            transcripts[index].translationSegments = segments
            transcripts[index].translation = segments.map { $0.translation }.joined(separator: " ")
            print("✅ [分句翻譯] 精確匹配到 transcripts[\(index)]，\(segments.count) 段")
        }
        // ⭐️ 模糊匹配：只允許 transcript 是 sourceText 的延伸，且只在無翻譯時填入
        else if let index = transcripts.firstIndex(where: { transcript in
            let textMatch = transcript.text.hasPrefix(sourceText) && sourceText != transcript.text
            guard textMatch else { return false }

            if let transcriptLang = transcript.language {
                let transcriptLangBase = transcriptLang.split(separator: "-").first.map(String.init) ?? transcriptLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                if transcriptLangBase != sourceTextLangBase {
                    return false
                }
            }
            return true
        }) {
            detectedLanguage = transcripts[index].language
            // ⭐️ 同 handleTranslation 的覆蓋策略
            let hasExisting = transcripts[index].translation != nil && !transcripts[index].translation!.isEmpty
            let finalText = transcripts[index].text
            let coversFullFinal = translationSourceCoversFinalText(sourceText: sourceText, finalText: finalText) ||
                translationSegmentsCoverFinalText(segments, finalText: finalText)

            guard coversFullFinal else {
                print("⏭️ [分句翻譯] 舊分句只覆蓋 final 前段，拒絕套用")
                print("   sourceText: \"\(sourceText.prefix(40))...\"")
                print("   finalText: \"\(finalText.prefix(50))...\"")
                requestFullRetranslationIfNeeded(for: finalText, reason: "分句翻譯未覆蓋完整 final")
                return
            }

            if !hasExisting || coversFullFinal {
                if !hasExisting { shouldPlayTTS = true }
                transcripts[index].translationSegments = segments
                transcripts[index].translation = segments.map { $0.translation }.joined(separator: " ")
                print("✅ [分句翻譯] 模糊匹配到 transcripts[\(index)]（完整覆蓋）")
            }
        }
        // ⭐️ 匹配 interimTranscript
        else if let interim = interimTranscript {
            // ⭐️ 同 handleTranslation：移除 sourceText.hasPrefix(interim.text) 防止跨句污染
            let textMatch = interim.text == sourceText ||
                           interim.text.hasPrefix(sourceText)

            var langMatch = true
            if let interimLang = interim.language {
                let interimLangBase = interimLang.split(separator: "-").first.map(String.init) ?? interimLang
                let sourceTextLangBase = sourceTextLang.split(separator: "-").first.map(String.init) ?? sourceTextLang
                langMatch = interimLangBase == sourceTextLangBase
            }

            if textMatch && langMatch {
                // ⭐️ 連續說話時一律更新翻譯
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
        calculateNewTTSContent(
            playedText: streamingTTSState.playedTranslation,
            fullTranslation: fullTranslation
        )
    }

    private func calculateNewTTSContent(playedText: String, fullTranslation: String) -> String {
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
        // 這通常代表同一個 source 的翻譯被大幅改寫；為了避免重播已經說過的內容，等待下一個穩定片段。
        print("⚠️ [Streaming TTS] 翻譯完全不同，避免重播整句")
        return ""
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

    /// ⭐️ 正規化文本用於比較（移除空格和常見標點）
    private func normalizeTextForComparison(_ text: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.whitespaces)
        return text.lowercased()
            .unicodeScalars
            .filter { !punctuation.contains($0) }
            .map { Character($0) }
            .map { String($0) }
            .joined()
    }

    /// 重置 Streaming TTS 狀態（在停止錄音時調用）
    private func resetStreamingTTSState() {
        // 取消計時器
        streamingTTSTimer?.invalidate()
        streamingTTSTimer = nil

        streamingTTSState.reset()
        print("🔄 [Streaming TTS] 狀態已重置")
    }

    /// ⭐️ 將翻譯加入待播放（等待對話框穩定後播放）
    /// 新策略：不立即播放，而是等待確認對話框不再變化
    /// 觸發播放的條件：
    /// 1. 穩定計時器到期（對話框在 stableDialogDelay 秒內沒有變化）
    /// 2. 檢測到新句子開始（在 handleTranscript 中處理）
    /// 3. 用戶停止錄音（在 stopRecording 中處理）
    func enqueueTTS(text: String, languageCode: String) {
        guard !text.isEmpty else { return }

        // ⭐️ 去重：正規化文本（移除空格和標點比較）
        let normalizedText = normalizeTextForComparison(text)

        // ⭐️ 檢查是否已播放過相同內容
        if playedTranslations.contains(normalizedText) {
            print("⚠️ [TTS] 忽略（已播放過相同內容）: \"\(text.prefix(25))...\"")
            return
        }

        // ⭐️ 去重：檢查隊列中是否已有相同文本（只檢查精確匹配）
        if ttsQueue.contains(where: { normalizeTextForComparison($0.text) == normalizedText }) {
            print("⚠️ [TTS Queue] 忽略相同文本: \"\(text.prefix(25))...\"")
            return
        }

        // ⭐️ 去重：檢查當前正在合成/播放的是否相同（只檢查精確匹配）
        if let synthesizing = currentSynthesizingText {
            if normalizeTextForComparison(synthesizing) == normalizedText {
                print("⚠️ [TTS] 忽略（正在合成相同內容）: \"\(text.prefix(25))...\"")
                return
            }
        }
        if let playing = audioManager.currentTTSText ?? appleTTSCurrentText {
            if normalizeTextForComparison(playing) == normalizedText {
                print("⚠️ [TTS] 忽略（正在播放相同內容）: \"\(text.prefix(25))...\"")
                return
            }
        }

        // ⭐️ 穩定對話框機制：等待對話框確定後再播放
        if let pending = pendingTTS {
            // 如果新翻譯是 pending 的延續（更完整的版本），替換並重置計時器
            if text.contains(pending.text) || pending.text.contains(text) {
                let newText = text.count > pending.text.count ? text : pending.text
                print("🔄 [TTS 穩定] 對話框更新，替換待播放")
                print("   舊: \"\(pending.text.prefix(25))...\"")
                print("   新: \"\(newText.prefix(25))...\"")
                pendingTTS = (text: newText, lang: languageCode, transcriptText: lastFinalText)
                // 重置穩定計時器
                stableDialogTimer?.invalidate()
                stableDialogTimer = Timer.scheduledTimer(withTimeInterval: stableDialogDelay, repeats: false) { [weak self] _ in
                    self?.flushPendingTTS()
                }
                return
            }
            // 如果是完全不同的翻譯（新句子），先播放舊的
            print("🔀 [TTS 穩定] 檢測到不同翻譯，先 flush 舊的")
            flushPendingTTS()
        }

        // ⭐️ 設置待播放內容並啟動穩定計時器
        pendingTTS = (text: text, lang: languageCode, transcriptText: lastFinalText)
        stableDialogTimer?.invalidate()
        stableDialogTimer = Timer.scheduledTimer(withTimeInterval: stableDialogDelay, repeats: false) { [weak self] _ in
            self?.flushPendingTTS()
        }
        print("⏳ [TTS 穩定] 等待對話框穩定 \(stableDialogDelay)s: \"\(text.prefix(25))...\"")
    }

    /// ⭐️ 直接加入 TTS 隊列（跳過穩定等待）
    private func directEnqueueTTS(text: String, languageCode: String) {
        ttsQueue.append((text: text, lang: languageCode))
        print("📥 [TTS Queue] 直接加入: \"\(text.prefix(25))...\" (隊列長度: \(ttsQueue.count))")

        if !isProcessingTTS {
            print("▶️ [TTS] 開始處理隊列")
            processNextTTS()
        }
    }

    /// ⭐️ 對話框合併時取消舊對話的 TTS
    /// 只播放合併後對話的翻譯，避免播放不完整的舊翻譯
    private func cancelTTSForMergedDialog(oldText: String) {
        print("🔄 [TTS] 對話框合併，取消舊對話 TTS")

        // 1. 取消 pendingTTS
        if pendingTTS != nil {
            print("   取消 pendingTTS: \"\(pendingTTS!.text.prefix(25))...\"")
            stableDialogTimer?.invalidate()
            stableDialogTimer = nil
            pendingTTS = nil
        }

        // 2. 從 TTS 隊列中移除（通常隊列中的翻譯與被合併的對話相關）
        if !ttsQueue.isEmpty {
            let removedCount = ttsQueue.count
            ttsQueue.removeAll()
            print("   清空 TTS 隊列（\(removedCount) 項）")
        }

        // 3. 停止當前正在播放的 TTS（可能是舊對話的翻譯）
        if isPlayingTTS {
            print("   停止當前播放的 TTS")
            switch ttsProvider {
            case .azure:
                audioManager.stopTTS()
            case .apple:
                appleTTSService.stop()
                isAppleTTSPlaying = false
                appleTTSCurrentText = nil
            }
            isProcessingTTS = false
            currentSynthesizingText = nil
        }

        // 4. 從已播放記錄中移除（允許新翻譯播放）
        // 不清除整個 playedTranslations，只移除可能與舊對話相關的
        // 實際上我們應該讓合併後的新翻譯能夠播放
        // 所以不需要額外處理

        print("   等待合併後對話的新翻譯")
    }

    /// ⭐️ 立即播放待播放的 TTS（穩定計時器觸發、新句子開始、或停止錄音）
    private func flushPendingTTS() {
        print("🔔 [TTS 穩定] flushPendingTTS 被調用")
        stableDialogTimer?.invalidate()
        stableDialogTimer = nil

        guard let pending = pendingTTS else {
            print("⚠️ [TTS 穩定] pendingTTS 為空，跳過")
            return
        }
        pendingTTS = nil

        print("🎵 [TTS 穩定] 對話框已穩定，準備播放: \"\(pending.text.prefix(30))...\"")
        print("   對應原文: \"\(pending.transcriptText.prefix(25))...\"")

        // ⭐️ 正規化文本用於去重
        let normalizedText = normalizeTextForComparison(pending.text)

        // ⭐️ 檢查是否已播放過
        if playedTranslations.contains(normalizedText) {
            print("⚠️ [TTS 穩定] 已播放過相同內容，跳過")
            return
        }

        // 再次檢查去重（只檢查精確匹配）
        if ttsQueue.contains(where: { normalizeTextForComparison($0.text) == normalizedText }) {
            print("⚠️ [TTS 穩定] 已在隊列中，跳過")
            return
        }
        if let synthesizing = currentSynthesizingText {
            if normalizeTextForComparison(synthesizing) == normalizedText {
                print("⚠️ [TTS 穩定] 正在合成相同內容，跳過")
                return
            }
        }
        if let playing = audioManager.currentTTSText ?? appleTTSCurrentText {
            if normalizeTextForComparison(playing) == normalizedText {
                print("⚠️ [TTS 穩定] 正在播放相同內容，跳過")
                return
            }
        }

        // ⭐️ 記錄已播放的翻譯（防止重複播放）
        recordPlayedTranslation(normalizedText)

        ttsQueue.append((text: pending.text, lang: pending.lang))
        print("📥 [TTS Queue] 對話框穩定，加入隊列: \"\(pending.text.prefix(25))...\" (隊列長度: \(ttsQueue.count))")

        // 如果沒有正在處理，開始處理
        if !isProcessingTTS {
            print("▶️ [TTS] 開始處理隊列")
            processNextTTS()
        } else {
            print("⏳ [TTS] 已有任務在處理，等待")
        }
    }

    /// ⭐️ 記錄已播放的翻譯（限制數量避免記憶體無限增長）
    private func recordPlayedTranslation(_ normalizedText: String) {
        playedTranslations.insert(normalizedText)
        // 如果超過限制，清除最早的記錄（Set 無序，簡單清除一半）
        if playedTranslations.count > maxPlayedTranslationsCount {
            let removeCount = maxPlayedTranslationsCount / 2
            for _ in 0..<removeCount {
                if let first = playedTranslations.first {
                    playedTranslations.remove(first)
                }
            }
            print("🧹 [TTS] 清理已播放記錄，剩餘: \(playedTranslations.count)")
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

        // ⭐️ 檢查是否有新的 transcript 進來（用戶還在說話）
        // 如果最近有新對話，跳過這個 TTS，讓新的翻譯取代
        if let lastTime = lastTranscriptTime {
            let timeSinceLastTranscript = Date().timeIntervalSince(lastTime)
            if timeSinceLastTranscript < ttsPrePlayCheckWindow {
                print("⏭️ [TTS] 跳過播放（\(String(format: "%.2f", timeSinceLastTranscript))s 前有新對話）: \"\(item.text.prefix(25))...\"")
                // 繼續處理隊列中的下一個（可能也會被跳過）
                processNextTTS()
                return
            }
        }

        // ⭐️ 檢查是否有待處理的新翻譯（pendingTTS 比當前隊列項目更新）
        if pendingTTS != nil {
            print("⏭️ [TTS] 跳過播放（有新的待播放翻譯）: \"\(item.text.prefix(25))...\"")
            processNextTTS()
            return
        }

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

                    // ⭐️ 合成完成後再次檢查是否應該播放
                    // 可能在合成期間有新的 transcript 進來
                    if let lastTime = lastTranscriptTime {
                        let timeSinceLastTranscript = Date().timeIntervalSince(lastTime)
                        if timeSinceLastTranscript < ttsPrePlayCheckWindow {
                            print("⏭️ [Azure TTS] 合成完成但跳過播放（\(String(format: "%.2f", timeSinceLastTranscript))s 前有新對話）")
                            currentSynthesizingText = nil
                            processNextTTS()
                            return
                        }
                    }
                    if pendingTTS != nil {
                        print("⏭️ [Azure TTS] 合成完成但跳過播放（有新的待播放翻譯）")
                        currentSynthesizingText = nil
                        processNextTTS()
                        return
                    }

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
                // Apple TTS：本地合成 → 緩衝播放（PCM 走 WebRTC EQ 鏈，支援 +36 dB 增益）
                print("🎙️ [Apple TTS Buffered] 播放中: \"\(item.text.prefix(30))...\"")

                isAppleTTSPlaying = true
                appleTTSCurrentText = item.text

                let textForCompletion = item.text
                do {
                    // 1) 開啟 WebRTC 那條 player → EQ → mainMixer 鏈
                    try audioManager.beginAppleTTSPlayback(text: item.text) { [weak self] in
                        // 真正全部播完才會跑這
                        guard let self = self else { return }
                        if self.appleTTSCurrentText == textForCompletion {
                            self.isAppleTTSPlaying = false
                            self.appleTTSCurrentText = nil
                        }
                        self.processNextTTS()
                    }

                    // 2) 啟動合成，每段 buffer 直接餵給 audioManager
                    appleTTSService.speakBuffered(
                        text: item.text,
                        languageCode: item.lang,
                        bufferHandler: { [weak self] buffer in
                            self?.audioManager.scheduleAppleTTSBuffer(buffer)
                        },
                        completion: { [weak self] in
                            // 合成器送完最後一個 buffer，標記等播放收尾
                            self?.audioManager.markAppleTTSSynthesisFinished()
                        }
                    )
                    currentSynthesizingText = nil
                } catch {
                    print("❌❌❌ [Apple TTS Buffered] 啟動失敗: \(error.localizedDescription)")
                    print("    ⚠️ 回退到直接播放路徑 — 此路徑無法套用音量增益！")
                    print("    可能原因：webrtcEngine 還沒就緒（通常是 TTS 在 startRecording 前就觸發）")
                    // ⭐️ 回退：用舊的直接播放路徑（無 EQ 增益但至少能播）
                    appleTTSService.speak(text: item.text, languageCode: item.lang)
                    currentSynthesizingText = nil
                }
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
            appleTTSService.stop()                // 停止合成器（含 buffered 模式的 write）
            audioManager.stopAppleTTSPlayback()   // 停止 WebRTC 那條播放鏈
            isAppleTTSPlaying = false
            appleTTSCurrentText = nil
        }
        ttsQueue.removeAll()
        isProcessingTTS = false

        // ⭐️ 清除 TTS 穩定對話框狀態
        stableDialogTimer?.invalidate()
        stableDialogTimer = nil
        pendingTTS = nil
        lastFinalText = ""
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
            audioManager.stopAppleTTSPlayback()   // 停止 WebRTC 那條播放鏈
            isAppleTTSPlaying = false
            appleTTSCurrentText = nil
        }
        // 不清空隊列，繼續播放下一個
        processNextTTS()
    }

    /// ⭐️ 立即播放指定的 TTS（中斷當前播放，清空隊列）
    /// 用於用戶手動點擊對話框的播放按鈕
    func playTTSImmediately(text: String, languageCode: String) {
        print("▶️ [TTS] 立即播放（中斷當前）: \"\(text.prefix(30))...\"")

        // 1. 停止當前播放
        switch ttsProvider {
        case .azure:
            audioManager.stopTTS()
        case .apple:
            appleTTSService.stop()
            isAppleTTSPlaying = false
            appleTTSCurrentText = nil
        }

        // 2. 清空隊列和 pending
        ttsQueue.removeAll()
        stableDialogTimer?.invalidate()
        stableDialogTimer = nil
        pendingTTS = nil
        isProcessingTTS = false
        currentSynthesizingText = nil

        // 3. 直接加入隊列並開始播放
        ttsQueue.append((text: text, lang: languageCode))
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
