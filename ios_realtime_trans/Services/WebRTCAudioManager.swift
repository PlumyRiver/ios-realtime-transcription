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
import WebRTC

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

    // MARK: - Combine Publishers

    private let audioDataSubject = PassthroughSubject<Data, Never>()

    var audioDataPublisher: AnyPublisher<Data, Never> {
        audioDataSubject.eraseToAnyPublisher()
    }

    /// TTS 播放完成回調
    var onTTSPlaybackFinished: (() -> Void)?

    /// PTT 結束語句回調
    var onEndUtterance: (() -> Void)?

    // MARK: - Initialization

    private override init() {
        super.init()
        setupWebRTC()
    }

    // MARK: - WebRTC Setup

    /// 設置 WebRTC
    private func setupWebRTC() {
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

        print("✅ [WebRTC] Factory 初始化完成")
        print("   模式: AudioEngine")
        print("   Voice Processing: 啟用（AEC 回音消除）")
        print("   Delegate: 已設置")
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

        recordingState = .recording
        print("🎙️ [WebRTC] 開始錄音（AudioEngine 模式）")
    }

    /// 停止錄音
    func stopRecording() {
        guard recordingState == .recording else { return }

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
        guard let data = convertToWebSocketFormat(buffer) else { return }
        audioBufferCollector.append(data)
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
        isManualSendingPaused = false
        print("🎙️ [WebRTC] 開始發送音頻")

        if !audioBufferCollector.isEmpty {
            print("📦 [WebRTC] 立即發送緩衝: \(audioBufferCollector.count) 個片段")
            flushBuffer()
        }
    }

    func stopSending() {
        flushRemainingAudio()
        sendTrailingSilence()
        onEndUtterance?()
        isManualSendingPaused = true
        print("⏸️ [WebRTC] 停止發送音頻")
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
        guard !audioBufferCollector.isEmpty else { return }

        if isManualSendingPaused {
            while audioBufferCollector.count > 4 {
                audioBufferCollector.removeFirst()
            }
            return
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
