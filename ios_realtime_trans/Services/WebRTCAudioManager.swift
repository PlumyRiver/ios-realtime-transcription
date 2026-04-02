//
//  WebRTCAudioManager.swift
//  ios_realtime_trans
//
//  使用 WebRTC AudioEngine 模式的全雙工音頻管理器
//
//  架構設計：
//  ┌────────────────────────────────────────────────────────────────┐
//  │  WebRTC RTCAudioDeviceModule (AudioEngine 模式)                 │
//  │                                                                 │
//  │  麥克風 → inputNode → [tapMixer + tap] → WebRTC 內部處理        │
//  │                              ↓                                  │
//  │                        PCM 數據 → WebSocket                     │
//  │                                                                 │
//  │  TTS 播放 → WebRTC outputNode → 揚聲器                          │
//  │                                                                 │
//  │  ⭐️ 全部使用 WebRTC 的 AudioEngine，AEC3 自動處理回音          │
//  └────────────────────────────────────────────────────────────────┘
//

import Foundation
import AVFoundation
import AVFAudio
import Combine
import CoreML
import WebRTC
import FluidAudio

// MARK: - Silero VAD Processor（線程安全的 ML 語音偵測）

actor SileroVADProcessor {
    private var vadManager: VadManager?
    private var streamState: VadStreamState = .initial()
    /// 累積 Int16 samples，湊滿 4096 後送入模型
    private var sampleBuffer: [Int16] = []

    func initialize() async throws {
        vadManager = try await VadManager(config: VadConfig(
            defaultThreshold: 0.5,
            computeUnits: .cpuAndNeuralEngine
        ))
        streamState = .initial()
        print("✅ [Silero VAD] 模型載入完成（chunk=4096, 256ms）")
    }

    var isReady: Bool { vadManager != nil }

    /// 處理 Int16 音訊樣本，回傳語音概率 (0.0 ~ 1.0)
    /// FluidAudio 每次需要 4096 samples (256ms @ 16kHz)
    func processSamples(_ samples: [Int16]) async -> Float {
        guard let vadManager else { return 0.0 }
        sampleBuffer.append(contentsOf: samples)
        var lastProbability: Float = 0.0
        while sampleBuffer.count >= VadManager.chunkSize {
            let chunk = Array(sampleBuffer.prefix(VadManager.chunkSize))
            sampleBuffer.removeFirst(VadManager.chunkSize)
            let floatChunk = chunk.map { Float($0) / 32768.0 }
            do {
                let result = try await vadManager.processStreamingChunk(
                    floatChunk,
                    state: streamState
                )
                lastProbability = result.probability
                streamState = result.state
            } catch {
                lastProbability = 0.0
            }
        }
        return lastProbability
    }

    /// 重置 LSTM 狀態（新對話時呼叫）
    func reset() async {
        sampleBuffer.removeAll()
        if let vadManager {
            streamState = await vadManager.makeStreamState()
        } else {
            streamState = .initial()
        }
    }
}

// MARK: - Recording State

enum WebRTCRecordingState: Equatable {
    case idle
    case recording
    case error(Error)

    static func == (lhs: WebRTCRecordingState, rhs: WebRTCRecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording, .recording): return true
        case (.error, .error): return true
        default: return false
        }
    }
}

// MARK: - VAD State（語音活動偵測狀態）

enum VADState: String {
    /// 偵測到說話中，正在發送音頻
    case speaking
    /// 偵測到靜音，但還沒超過閾值，繼續發送
    case silent
    /// 靜音超過閾值（2秒），暫停發送（不計費）
    case paused
}

// MARK: - Recording Error

enum WebRTCRecordingError: Error, LocalizedError {
    case permissionDenied
    case invalidFormat
    case engineStartFailed
    case webrtcInitFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "麥克風權限被拒絕"
        case .invalidFormat: return "音頻格式無效"
        case .engineStartFailed: return "音頻引擎啟動失敗"
        case .webrtcInitFailed: return "WebRTC 初始化失敗"
        }
    }
}

// MARK: - TTS Error

enum WebRTCTTSError: Error, LocalizedError {
    case audioFileError
    case playbackFailed
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .audioFileError: return "音頻文件錯誤"
        case .playbackFailed: return "播放失敗"
        case .engineNotReady: return "音頻引擎未準備好"
        }
    }
}

// MARK: - WebRTC Audio Manager

/// WebRTC AudioEngine 模式全雙工音頻管理器
@Observable
final class WebRTCAudioManager: NSObject {

    // MARK: - Singleton

    static let shared = WebRTCAudioManager()

    // MARK: - Public Properties

    /// 錄音狀態
    private(set) var recordingState: WebRTCRecordingState = .idle

    /// TTS 播放狀態
    private(set) var isPlayingTTS: Bool = false

    /// 當前播放的 TTS 文本
    private(set) var currentTTSText: String?

    /// Push-to-Talk 模式
    private(set) var isManualSendingPaused: Bool = true

    /// 擴音模式
    var isSpeakerMode: Bool = true {
        didSet {
            if oldValue != isSpeakerMode {
                updateOutputRoute()
            }
        }
    }

    /// 音量增益（dB）
    static let maxVolumeDB: Float = 36.0
    var volumeBoostDB: Float = 24.0 {
        didSet {
            updateVolumeGain()
        }
    }

    /// 音量百分比
    var volumePercent: Float {
        get { volumeBoostDB / Self.maxVolumeDB }
        set {
            let clamped = min(max(newValue, 0), 1)
            volumeBoostDB = clamped * Self.maxVolumeDB
        }
    }

    // MARK: - 麥克風增益設定

    /// ⭐️ 麥克風增益（1.0 = 原始音量，2.0 = 兩倍，最大 4.0）
    /// 用於放大細微聲音，讓 ElevenLabs 更容易偵測
    static let maxMicGain: Float = 4.0
    static let defaultMicGain: Float = 1.0

    var microphoneGain: Float = 1.0 {
        didSet {
            let clamped = min(max(microphoneGain, 1.0), Self.maxMicGain)
            if microphoneGain != clamped {
                microphoneGain = clamped
            }
            print("🎤 [WebRTC] 麥克風增益: \(microphoneGain)x")
        }
    }

    // MARK: - WebRTC Components

    /// PeerConnection Factory
    private var factory: RTCPeerConnectionFactory!

    /// AudioDeviceModule
    private var audioDeviceModule: RTCAudioDeviceModule!

    /// WebRTC 管理的 AVAudioEngine（通過 delegate 獲取）
    private var webrtcEngine: AVAudioEngine?

    /// 本地音頻軌道
    private var localAudioTrack: RTCAudioTrack?

    /// 音頻源
    private var audioSource: RTCAudioSource?

    // MARK: - Audio Tap（在 WebRTC Engine 中捕獲音頻）

    /// 用於捕獲輸入音頻的 Mixer 節點
    private var tapMixerNode: AVAudioMixerNode?

    /// 音頻格式轉換器
    private var audioConverter: AVAudioConverter?

    /// 輸出格式（16kHz mono 16-bit）
    private var outputFormat: AVAudioFormat?

    // MARK: - TTS Playback（使用 WebRTC Engine 播放）

    /// TTS 播放器節點（連接到 WebRTC Engine）
    private var ttsPlayerNode: AVAudioPlayerNode?

    /// TTS EQ 節點
    private var ttsEQNode: AVAudioUnitEQ?

    /// TTS 音頻文件
    private var ttsAudioFile: AVAudioFile?

    /// 播放監控定時器
    private var playbackTimer: Timer?

    /// 防止重複觸發完成回調
    private var hasTriggeredCompletion: Bool = false

    /// TTS 節點是否已連接
    private var ttsNodesConnected: Bool = false

    // MARK: - Audio Buffer

    private var audioBufferCollector: [Data] = []
    private var bufferTimer: Timer?
    private let bufferInterval: TimeInterval = 0.25
    private var sendCount = 0
    private let maxChunkSize = 25600

    // MARK: - PTT 尾音緩衝（放開按鈕後繼續發送 0.5 秒）

    /// ⭐️ PTT 尾音緩衝計時器
    private var pttTrailingTimer: Timer?

    /// ⭐️ PTT 尾音緩衝時間（秒）
    private let pttTrailingDuration: TimeInterval = 0.5

    /// ⭐️ 是否正在發送尾音緩衝
    private(set) var isTrailingBuffer: Bool = false

    // MARK: - VAD 系統（語音活動偵測）
    // ⭐️ 節省 STT 費用：靜音時停止發送音頻

    /// VAD 開關（預設關閉，由 ViewModel 控制）
    var isVADEnabled: Bool = false {
        didSet {
            if isVADEnabled {
                print("🎙️ [VAD] 已啟用（靜音 \(vadSilenceThreshold)s 後暫停發送）")
            } else {
                print("🎙️ [VAD] 已停用")
                // 停用時重置狀態
                vadState = .speaking
            }
        }
    }

    /// VAD 當前狀態
    private(set) var vadState: VADState = .paused

    /// ⭐️ Silero VAD 語音概率閾值（0.0 ~ 1.0）
    /// ML 模型判定語音概率超過此值才視為說話
    var vadSpeechThreshold: Float = 0.5

    /// ⭐️ Silero VAD 處理器
    private let sileroProcessor = SileroVADProcessor()

    /// VAD 靜音閾值（秒）- 靜音超過此時間暫停發送
    var vadSilenceThreshold: TimeInterval = 2.0

    /// VAD 前詞填充時間（秒）- 偵測到說話時發送之前緩衝的音頻
    var vadPreBufferDuration: TimeInterval = 0.5

    /// 靜音開始時間
    private var silenceStartTime: Date?

    /// Pre-buffer 環形緩衝區（持續保存最近 0.5 秒的音頻）
    /// 使用 (data, timestamp) 元組來追蹤每個塊的時間
    private var preBuffer: [(data: Data, timestamp: Date)] = []

    /// Pre-buffer 最大位元組數
    /// 16kHz * 2 bytes * 0.5 秒 = 16000 bytes
    private var preBufferMaxBytes: Int {
        Int(16000.0 * 2.0 * vadPreBufferDuration)
    }

    /// VAD 狀態變化回調（用於 UI 更新）
    var onVADStateChanged: ((VADState) -> Void)?

    // MARK: - Combine Publishers

    private let audioDataSubject = PassthroughSubject<Data, Never>()

    var audioDataPublisher: AnyPublisher<Data, Never> {
        audioDataSubject.eraseToAnyPublisher()
    }

    // MARK: - 即時音量監測

    /// ⭐️ 即時 RMS 音量（0.0 ~ 1.0，已正規化）
    private(set) var currentVolume: Float = 0.0

    /// ⭐️ 音量更新 Publisher（用於 UI 即時顯示）
    private let volumeSubject = PassthroughSubject<Float, Never>()

    var volumePublisher: AnyPublisher<Float, Never> {
        volumeSubject.eraseToAnyPublisher()
    }

    /// 音量平滑係數（0.0 ~ 1.0，越高越平滑但反應越慢）
    private let volumeSmoothingFactor: Float = 0.3

    /// TTS 播放完成回調
    var onTTSPlaybackFinished: (() -> Void)?

    /// PTT 結束語句回調
    var onEndUtterance: (() -> Void)?

    // MARK: - Initialization

    /// ⭐️ 是否已初始化 WebRTC
    private var isWebRTCInitialized = false
    private let initLock = NSLock()

    private override init() {
        super.init()
        // ⭐️ 不在 init 中同步初始化，改為延遲初始化
        // 在背景線程初始化，避免阻塞主線程
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.setupWebRTC()
        }
    }

    // MARK: - WebRTC Setup

    /// 設置 WebRTC（可在背景線程執行）
    private func setupWebRTC() {
        initLock.lock()
        defer { initLock.unlock() }

        guard !isWebRTCInitialized else { return }

        RTCInitializeSSL()

        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()

        // ⭐️ 使用 AudioEngine 模式，啟用 Voice Processing（AEC）
        factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: false,
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory,
            audioProcessingModule: nil
        )

        // 獲取 AudioDeviceModule 並設置 delegate
        audioDeviceModule = factory.audioDeviceModule
        audioDeviceModule.observer = self

        // 創建輸出格式
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )

        isWebRTCInitialized = true

        print("✅ [WebRTC] Factory 初始化完成（背景線程）")
        print("   模式: AudioEngine")
        print("   Voice Processing: 啟用（AEC 回音消除）")
        print("   Delegate: 已設置")
    }

    /// ⭐️ 確保 WebRTC 已初始化（在需要時調用）
    private func ensureInitialized() {
        if !isWebRTCInitialized {
            setupWebRTC()
        }
    }

    /// 更新輸出路由
    private func updateOutputRoute() {
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.lockForConfiguration()
        do {
            if isSpeakerMode {
                try rtcAudioSession.overrideOutputAudioPort(.speaker)
                print("📢 [WebRTC] 擴音模式：揚聲器")
            } else {
                try rtcAudioSession.overrideOutputAudioPort(.none)
                print("📱 [WebRTC] 聽筒模式")
            }
        } catch {
            print("❌ [WebRTC] 更新輸出路由失敗: \(error)")
        }
        rtcAudioSession.unlockForConfiguration()
    }

    // MARK: - Voice Isolation

    /// 顯示系統麥克風模式選擇器（Voice Isolation、Wide Spectrum、Standard）
    /// 需要在麥克風正在使用時調用
    func showMicrophoneModeSelector() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        print("🎤 [WebRTC] 顯示麥克風模式選擇器")
    }

    /// 獲取當前偏好的麥克風模式
    var preferredMicrophoneMode: AVCaptureDevice.MicrophoneMode {
        AVCaptureDevice.preferredMicrophoneMode
    }

    /// 獲取當前啟用的麥克風模式
    var activeMicrophoneMode: AVCaptureDevice.MicrophoneMode {
        AVCaptureDevice.activeMicrophoneMode
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording Methods

    /// 開始錄音
    func startRecording() throws {
        // ⭐️ 確保 WebRTC 已初始化
        ensureInitialized()

        guard recordingState != .recording else { return }

        // 配置音頻會話
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.lockForConfiguration()
        do {
            try rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord)
            try rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat)
            try rtcAudioSession.setActive(true)
        } catch {
            print("❌ [WebRTC] 音頻會話配置失敗: \(error)")
        }
        rtcAudioSession.unlockForConfiguration()

        updateOutputRoute()

        // 創建 WebRTC 音頻軌道
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "false",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true"
            ]
        )

        audioSource = factory.audioSource(with: audioConstraints)
        guard let source = audioSource else {
            throw WebRTCRecordingError.webrtcInitFailed
        }

        localAudioTrack = factory.audioTrack(with: source, trackId: "audio0")
        localAudioTrack?.isEnabled = true

        print("✅ [WebRTC] 音頻軌道已創建")
        print("   AEC: 啟用")

        // 初始化錄音（這會觸發 delegate 回調）
        let result = audioDeviceModule.initRecording()
        if result != 0 {
            print("⚠️ [WebRTC] initRecording 返回: \(result)")
        }

        // 開始錄音
        let startResult = audioDeviceModule.startRecording()
        if startResult != 0 {
            print("⚠️ [WebRTC] startRecording 返回: \(startResult)")
        }

        // 啟動緩衝區定時器
        startBufferTimer()

        // ⭐️ 重置 VAD 狀態
        resetVADState()

        // ⭐️ 初始化 Silero VAD（若尚未初始化）
        Task {
            if await !sileroProcessor.isReady {
                do {
                    try await sileroProcessor.initialize()
                } catch {
                    print("❌ [Silero VAD] 初始化失敗: \(error)，將使用直通模式")
                }
            }
        }

        // ⭐️ 預先建立 TTS 播放節點（避免第一次播放時延遲）
        preInitTTSNodes()

        recordingState = .recording
        print("🎙️ [WebRTC] 開始錄音（AudioEngine 模式）")
        if isVADEnabled {
            print("   VAD: 啟用（Silero 閾值: \(vadSpeechThreshold), 靜音: \(vadSilenceThreshold)s）")
        }
    }

    /// 停止錄音
    func stopRecording() {
        guard recordingState == .recording else { return }

        // ⭐️ 停止尾音緩衝計時器
        pttTrailingTimer?.invalidate()
        pttTrailingTimer = nil
        isTrailingBuffer = false

        stopBufferTimer()
        flushBuffer()

        // 移除 tap
        tapMixerNode?.removeTap(onBus: 0)
        tapMixerNode = nil

        // 停止 WebRTC 錄音
        audioDeviceModule.stopRecording()

        // 停止 TTS
        stopTTS()

        // 停止音頻軌道
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        audioSource = nil

        print("⏹️ [WebRTC] 停止錄音 (總計發送 \(sendCount) 次)")
        sendCount = 0
        recordingState = .idle
        isManualSendingPaused = true
    }

    // MARK: - Audio Processing

    /// 處理從 tap 接收的音頻數據
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // ⭐️ 如果有設定麥克風增益，先放大音頻
        if microphoneGain > 1.0 {
            amplifyInputBuffer(buffer, gain: microphoneGain)
        }

        // ⭐️ 計算並更新即時音量（保留：UI 音量顯示）
        let rms = calculateRMS(buffer)
        updateVolume(rms)

        guard let data = convertToWebSocketFormat(buffer) else { return }

        // ⭐️ Silero VAD 處理：ML 模型判斷語音活動
        if isVADEnabled && !isManualSendingPaused {
            // 提取 Int16 samples 給 Silero
            let samples = data.withUnsafeBytes { rawBuffer -> [Int16] in
                let typedBuffer = rawBuffer.bindMemory(to: Int16.self)
                return Array(typedBuffer)
            }
            let audioData = data
            Task { [weak self] in
                guard let self else { return }
                let isReady = await self.sileroProcessor.isReady
                if isReady {
                    let probability = await self.sileroProcessor.processSamples(samples)
                    self.updateVADState(speechProbability: probability, audioData: audioData)
                } else {
                    // Silero 未就緒，直通模式
                    self.audioBufferCollector.append(audioData)
                }
            }
        } else {
            // VAD 未啟用，直接加入緩衝區
            audioBufferCollector.append(data)
        }
    }

    // MARK: - VAD Processing

    /// 更新 VAD 狀態（Silero ML 語音偵測）
    /// - Parameters:
    ///   - speechProbability: Silero VAD 語音概率 (0.0 ~ 1.0)
    ///   - audioData: 當前音頻數據
    private func updateVADState(speechProbability: Float, audioData: Data) {
        let isSpeaking = speechProbability >= vadSpeechThreshold
        let previousState = vadState

        if isSpeaking {
            // ⭐️ 偵測到說話
            silenceStartTime = nil

            if vadState == .paused {
                // 從暫停恢復：先發送 pre-buffer（前詞填充）
                let preBufferData = getPreBufferData()
                let preBufferMs = Int(preBufferDuration * 1000)
                print("🎤 [VAD] 偵測到說話，發送 \(preBufferData.count) 個前詞填充（\(preBufferMs)ms）")
                vadState = .speaking

                // ⭐️ 通知計費系統開始計費
                BillingService.shared.startAudioSending()

                // 發送 pre-buffer
                for preData in preBufferData {
                    audioBufferCollector.append(preData)
                }
                preBuffer.removeAll()
            } else {
                vadState = .speaking
            }

            // 加入當前音頻
            audioBufferCollector.append(audioData)

        } else {
            // ⭐️ 偵測到靜音
            if silenceStartTime == nil {
                silenceStartTime = Date()
            }

            let silenceDuration = Date().timeIntervalSince(silenceStartTime!)

            if silenceDuration >= vadSilenceThreshold {
                // 靜音超過閾值，暫停發送
                if vadState != .paused {
                    print("🔇 [VAD] 靜音 \(String(format: "%.1f", silenceDuration))s，暫停發送")
                    vadState = .paused

                    // ⭐️ 發送剩餘緩衝區和尾音
                    flushRemainingAudio()
                    sendTrailingSilence()
                    onEndUtterance?()

                    // ⭐️ 通知計費系統停止計費
                    BillingService.shared.stopAudioSending()
                }

                // 暫停狀態：只保存到 pre-buffer（不發送）
                addToPreBuffer(audioData)

            } else {
                // 靜音但還沒超過閾值，繼續發送
                vadState = .silent
                audioBufferCollector.append(audioData)
            }
        }

        // 狀態變化回調
        if previousState != vadState {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onVADStateChanged?(self.vadState)
            }
        }
    }

    /// 加入 Pre-buffer（環形緩衝區）
    /// 基於位元組數而非數量，確保精確的時間長度
    private func addToPreBuffer(_ data: Data) {
        preBuffer.append((data: data, timestamp: Date()))

        // 保持緩衝區大小不超過最大位元組數
        var totalBytes = preBuffer.reduce(0) { $0 + $1.data.count }
        while totalBytes > preBufferMaxBytes && preBuffer.count > 1 {
            totalBytes -= preBuffer.removeFirst().data.count
        }
    }

    /// 獲取 pre-buffer 中的所有音頻數據
    private func getPreBufferData() -> [Data] {
        preBuffer.map { $0.data }
    }

    /// Pre-buffer 當前總位元組數
    private var preBufferTotalBytes: Int {
        preBuffer.reduce(0) { $0 + $1.data.count }
    }

    /// Pre-buffer 當前時長（秒）
    private var preBufferDuration: TimeInterval {
        Double(preBufferTotalBytes) / (16000.0 * 2.0)
    }

    /// 重置 VAD 狀態（開始錄音時調用）
    private func resetVADState() {
        vadState = isVADEnabled ? .paused : .speaking
        silenceStartTime = nil
        preBuffer.removeAll()
        // ⭐️ 重置 Silero LSTM 狀態
        Task { await sileroProcessor.reset() }
    }

    /// ⭐️ 放大輸入音頻緩衝區（in-place 修改）
    private func amplifyInputBuffer(_ buffer: AVAudioPCMBuffer, gain: Float) {
        guard gain > 1.0 else { return }

        // Float 格式
        if let floatChannelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)

            for channel in 0..<channelCount {
                let samples = floatChannelData[channel]
                for frame in 0..<frameLength {
                    // 放大並限制在 -1.0 ~ 1.0
                    samples[frame] = min(max(samples[frame] * gain, -1.0), 1.0)
                }
            }
        }
        // Int16 格式
        else if let int16ChannelData = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)

            for channel in 0..<channelCount {
                let samples = int16ChannelData[channel]
                for frame in 0..<frameLength {
                    // 放大並限制在 Int16 範圍
                    let amplified = Float(samples[frame]) * gain
                    samples[frame] = Int16(min(max(amplified, -32768), 32767))
                }
            }
        }
    }

    /// ⭐️ 計算 RMS（Root Mean Square）音量
    /// - Parameter buffer: 音頻緩衝區
    /// - Returns: RMS 音量（0.0 ~ 1.0）
    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            // 嘗試從 int16 數據計算
            if let int16Data = buffer.int16ChannelData {
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return 0 }

                var sum: Float = 0
                for i in 0..<frameLength {
                    let sample = Float(int16Data[0][i]) / 32768.0  // 正規化到 -1.0 ~ 1.0
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameLength))
                return min(rms * 3.0, 1.0)  // 放大並限制在 0~1
            }
            return 0
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[0][i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        // 將 RMS 正規化到 0~1 範圍（通常語音 RMS 在 0.01~0.3 之間）
        return min(rms * 3.0, 1.0)
    }

    /// ⭐️ 更新音量（帶平滑處理）
    private func updateVolume(_ newRMS: Float) {
        // 指數移動平均（EMA）平滑
        currentVolume = currentVolume * volumeSmoothingFactor + newRMS * (1.0 - volumeSmoothingFactor)

        // 發送到 Publisher（用於 UI 更新）
        volumeSubject.send(currentVolume)
    }

    /// 轉換音頻格式
    private func convertToWebSocketFormat(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let outFormat = outputFormat else { return nil }

        let inputFormat = buffer.format

        // 如果已經是目標格式
        if inputFormat.sampleRate == 16000 &&
           inputFormat.channelCount == 1 &&
           inputFormat.commonFormat == .pcmFormatInt16 {
            if let channelData = buffer.int16ChannelData {
                let frameLength = Int(buffer.frameLength)
                return Data(bytes: channelData[0], count: frameLength * 2)
            }
        }

        // 需要轉換
        if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: outFormat)
        }

        guard let converter = audioConverter else { return nil }

        let ratio = outFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: outputFrameCapacity
        ) else { return nil }

        var hasProvidedData = false
        var error: NSError?

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvidedData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil { return nil }

        if let channelData = outputBuffer.int16ChannelData {
            let frameLength = Int(outputBuffer.frameLength)
            if frameLength > 0 {
                return Data(bytes: channelData[0], count: frameLength * 2)
            }
        }

        return nil
    }

    // MARK: - Push-to-Talk

    func startSending() {
        // ⭐️ 取消尾音緩衝計時器（如果正在運行）
        pttTrailingTimer?.invalidate()
        pttTrailingTimer = nil
        isTrailingBuffer = false

        isManualSendingPaused = false

        if isVADEnabled {
            // ⭐️ VAD 模式：從 paused 開始，等偵測到說話再發送
            // 計費會在 updateVADState() 中偵測到說話時開始
            print("🎙️ [WebRTC] 開始監聽（VAD 模式，等待偵測說話）")
        } else {
            // ⭐️ 非 VAD 模式：立即開始發送和計費
            print("🎙️ [WebRTC] 開始發送音頻")
            BillingService.shared.startAudioSending()

            if !audioBufferCollector.isEmpty {
                print("📦 [WebRTC] 立即發送緩衝: \(audioBufferCollector.count) 個片段")
                flushBuffer()
            }
        }
    }

    func stopSending() {
        if isVADEnabled && vadState == .paused {
            // ⭐️ VAD 模式且目前是 paused：直接停止，不需要尾音緩衝
            isManualSendingPaused = true
            preBuffer.removeAll()
            print("⏸️ [WebRTC] 停止監聽（VAD 模式，目前已是暫停狀態）")
            return
        }

        // ⭐️ 開始尾音緩衝：繼續發送 0.5 秒的音頻
        isTrailingBuffer = true
        print("🔊 [WebRTC] 開始 \(pttTrailingDuration) 秒尾音緩衝")

        pttTrailingTimer?.invalidate()
        pttTrailingTimer = Timer.scheduledTimer(withTimeInterval: pttTrailingDuration, repeats: false) { [weak self] _ in
            self?.finishStopSending()
        }
    }

    /// ⭐️ 尾音緩衝結束後，真正停止發送
    private func finishStopSending() {
        isTrailingBuffer = false

        // 發送剩餘音頻和靜音
        flushRemainingAudio()
        sendTrailingSilence()
        onEndUtterance?()

        // ⭐️ 通知 BillingService 停止計費（只有非 VAD 模式或 VAD 正在發送時）
        if !isVADEnabled || vadState != .paused {
            BillingService.shared.stopAudioSending()
        }

        isManualSendingPaused = true
        print("⏸️ [WebRTC] 停止發送音頻（尾音緩衝結束）")
    }

    private func flushRemainingAudio() {
        guard !audioBufferCollector.isEmpty else { return }

        var combinedData = Data()
        for buffer in audioBufferCollector {
            combinedData.append(buffer)
        }
        audioBufferCollector.removeAll()

        if combinedData.isEmpty { return }

        var offset = 0
        while offset < combinedData.count {
            let chunkSize = min(maxChunkSize, combinedData.count - offset)
            let chunk = combinedData.subdata(in: offset..<(offset + chunkSize))
            sendCount += 1
            audioDataSubject.send(chunk)
            offset += chunkSize
        }
    }

    private func sendTrailingSilence() {
        let bytesPerChunk = 8000
        for _ in 0..<4 {
            let silenceData = Data(count: bytesPerChunk)
            sendCount += 1
            audioDataSubject.send(silenceData)
        }
        print("🔇 [WebRTC] 發送尾部靜音")
    }

    // MARK: - TTS Playback

    /// 播放 TTS 音頻（通過 WebRTC Engine 播放，AEC 自動處理回音）
    /// ⭐️ 預先建立 TTS 節點並連接到 WebRTC Engine（避免第一次播放卡頓）
    func preInitTTSNodes() {
        guard let engine = webrtcEngine else { return }
        guard !ttsNodesConnected else { return }

        if ttsPlayerNode == nil {
            ttsPlayerNode = AVAudioPlayerNode()
            ttsEQNode = AVAudioUnitEQ(numberOfBands: 3)
        }

        guard let player = ttsPlayerNode, let eq = ttsEQNode else { return }

        engine.attach(player)
        engine.attach(eq)

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        ttsNodesConnected = true
        updateVolumeGain()
        print("✅ [WebRTC] TTS 節點預先建立完成")
    }

    func playTTS(audioData: Data, text: String? = nil) throws {
        stopTTS()

        guard let engine = webrtcEngine else {
            print("❌ [WebRTC] Engine 未準備好，無法播放 TTS")
            throw WebRTCTTSError.engineNotReady
        }

        currentTTSText = text
        isPlayingTTS = true
        hasTriggeredCompletion = false

        // 創建播放節點（如果還沒有）
        if ttsPlayerNode == nil {
            ttsPlayerNode = AVAudioPlayerNode()
            ttsEQNode = AVAudioUnitEQ(numberOfBands: 3)
        }

        guard let player = ttsPlayerNode, let eq = ttsEQNode else {
            throw WebRTCTTSError.playbackFailed
        }

        // 連接節點到 WebRTC Engine（如果還沒連接）
        if !ttsNodesConnected {
            engine.attach(player)
            engine.attach(eq)

            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)

            ttsNodesConnected = true
            updateVolumeGain()
            print("✅ [WebRTC] TTS 節點已連接到 WebRTC Engine")
        }

        // 寫入臨時文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try audioData.write(to: tempURL)

        ttsAudioFile = try AVAudioFile(forReading: tempURL)

        guard let audioFile = ttsAudioFile else {
            throw WebRTCTTSError.audioFileError
        }

        print("🔊 [WebRTC] TTS 播放中（全雙工，AEC 處理回音）")
        print("   文本: \(text?.prefix(30) ?? "unknown")...")
        print("   增益: +\(Int(volumeBoostDB)) dB")

        player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onTTSPlaybackComplete(tempURL: tempURL)
            }
        }

        player.play()
        startPlaybackMonitor()
    }

    private func onTTSPlaybackComplete(tempURL: URL) {
        guard !hasTriggeredCompletion else { return }
        hasTriggeredCompletion = true

        print("✅ [WebRTC] TTS 播放完成")
        isPlayingTTS = false
        currentTTSText = nil

        playbackTimer?.invalidate()
        playbackTimer = nil

        try? FileManager.default.removeItem(at: tempURL)
        onTTSPlaybackFinished?()
    }

    func stopTTS() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        ttsPlayerNode?.stop()

        if let audioFile = ttsAudioFile {
            try? FileManager.default.removeItem(at: audioFile.url)
        }
        ttsAudioFile = nil

        isPlayingTTS = false
        currentTTSText = nil
    }

    private func startPlaybackMonitor() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self,
                  let player = self.ttsPlayerNode else {
                timer.invalidate()
                return
            }

            if !player.isPlaying && self.isPlayingTTS {
                timer.invalidate()
                if let url = self.ttsAudioFile?.url {
                    self.onTTSPlaybackComplete(tempURL: url)
                }
            }
        }
    }

    /// 更新音量增益
    private func updateVolumeGain() {
        guard let eq = ttsEQNode else { return }

        let perBandGain = volumeBoostDB / 3.0

        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 250
        eq.bands[0].gain = perBandGain
        eq.bands[0].bypass = false

        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 1000
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = perBandGain
        eq.bands[1].bypass = false

        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 4000
        eq.bands[2].gain = perBandGain
        eq.bands[2].bypass = false

        print("🔊 [WebRTC] 音量增益: +\(Int(volumeBoostDB)) dB")
    }

    // MARK: - Buffer Management

    private func startBufferTimer() {
        bufferTimer = Timer.scheduledTimer(withTimeInterval: bufferInterval, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }
    }

    private func stopBufferTimer() {
        bufferTimer?.invalidate()
        bufferTimer = nil
    }

    private func flushBuffer() {
        // ⭐️ 安全檢查：確保在主線程執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.flushBuffer()
            }
            return
        }

        guard !audioBufferCollector.isEmpty else { return }

        if isManualSendingPaused {
            // ⭐️ 安全檢查：避免無限循環
            let removeCount = min(audioBufferCollector.count - 4, audioBufferCollector.count)
            if removeCount > 0 {
                audioBufferCollector.removeFirst(removeCount)
            }
            return
        }

        // ⭐️ 安全檢查：限制緩衝區大小，避免記憶體爆炸
        if audioBufferCollector.count > 100 {
            print("⚠️ [WebRTC] 緩衝區過大 (\(audioBufferCollector.count))，清理舊數據")
            audioBufferCollector.removeFirst(audioBufferCollector.count - 20)
        }

        var combinedData = Data()
        for buffer in audioBufferCollector {
            combinedData.append(buffer)
        }
        audioBufferCollector.removeAll()

        var offset = 0
        while offset < combinedData.count {
            let chunkSize = min(maxChunkSize, combinedData.count - offset)
            let chunk = combinedData.subdata(in: offset..<(offset + chunkSize))

            sendCount += 1
            if sendCount == 1 || sendCount % 20 == 0 {
                print("📤 [WebRTC] 發送音頻 #\(sendCount): \(chunk.count) bytes")
            }
            audioDataSubject.send(chunk)

            offset += chunkSize
        }
    }
}

// MARK: - RTCAudioDeviceModuleDelegate

extension WebRTCAudioManager: RTCAudioDeviceModuleDelegate {

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {
        switch speechActivityEvent {
        case .started:
            print("🎤 [WebRTC] 語音活動開始")
        case .ended:
            print("🔇 [WebRTC] 語音活動結束")
        @unknown default:
            break
        }
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          didCreateEngine engine: AVAudioEngine) -> Int {
        print("✅ [WebRTC Delegate] AVAudioEngine 已創建")
        self.webrtcEngine = engine
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          willEnableEngine engine: AVAudioEngine,
                          isPlayoutEnabled: Bool,
                          isRecordingEnabled: Bool) -> Int {
        print("🔧 [WebRTC Delegate] Engine 即將啟用")
        print("   Playout: \(isPlayoutEnabled), Recording: \(isRecordingEnabled)")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          willStartEngine engine: AVAudioEngine,
                          isPlayoutEnabled: Bool,
                          isRecordingEnabled: Bool) -> Int {
        print("▶️ [WebRTC Delegate] Engine 即將啟動")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          didStopEngine engine: AVAudioEngine,
                          isPlayoutEnabled: Bool,
                          isRecordingEnabled: Bool) -> Int {
        print("⏹️ [WebRTC Delegate] Engine 已停止")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          didDisableEngine engine: AVAudioEngine,
                          isPlayoutEnabled: Bool,
                          isRecordingEnabled: Bool) -> Int {
        print("🔇 [WebRTC Delegate] Engine 已禁用")
        ttsNodesConnected = false
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          willReleaseEngine engine: AVAudioEngine) -> Int {
        print("🗑️ [WebRTC Delegate] Engine 即將釋放")
        self.webrtcEngine = nil
        ttsNodesConnected = false
        return 0
    }

    /// ⭐️ 關鍵：配置輸入路徑 - 在這裡安裝 tap 捕獲音頻
    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          engine: AVAudioEngine,
                          configureInputFromSource source: AVAudioNode?,
                          toDestination destination: AVAudioNode,
                          format: AVAudioFormat,
                          context: [AnyHashable: Any]) -> Int {
        print("🎤 [WebRTC Delegate] 配置輸入路徑")
        print("   Source: \(source != nil ? "inputNode" : "nil")")
        print("   Format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        guard let inputSource = source else {
            print("⚠️ [WebRTC Delegate] Source 為 nil，無法安裝 tap")
            return 0
        }

        // ⭐️ 啟用 Voice Processing（支援系統 Voice Isolation）
        let inputNode = engine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingAGCEnabled = true
            inputNode.isVoiceProcessingBypassed = false
            print("✅ [WebRTC Delegate] Voice Processing 已啟用（支援 Voice Isolation）")
        } catch {
            print("⚠️ [WebRTC Delegate] Voice Processing 啟用失敗: \(error)")
        }

        // 創建 Mixer 節點用於 tap
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)

        // 連接：source → mixer → destination
        engine.connect(inputSource, to: mixer, format: format)
        engine.connect(mixer, to: destination, format: format)

        // 在 mixer 上安裝 tap
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        self.tapMixerNode = mixer
        print("✅ [WebRTC Delegate] Tap 已安裝到輸入路徑")

        return 0
    }

    /// 配置輸出路徑
    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                          engine: AVAudioEngine,
                          configureOutputFromSource source: AVAudioNode,
                          toDestination destination: AVAudioNode?,
                          format: AVAudioFormat,
                          context: [AnyHashable: Any]) -> Int {
        print("🔊 [WebRTC Delegate] 配置輸出路徑")
        print("   Format: \(format.sampleRate)Hz, \(format.channelCount)ch")
        return 0
    }

    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {
        print("🔄 [WebRTC Delegate] 設備列表已更新")
    }
}
