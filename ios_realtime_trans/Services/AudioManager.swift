//
//  AudioManager.swift
//  ios_realtime_trans
//
//  統一音頻管理器：整合錄音和 TTS 播放到同一個 AVAudioEngine
//  利用 iOS Voice Processing I/O 的原生回音消除（AEC）
//
//  原理：
//  - Voice Processing I/O 會自動從麥克風輸入中減去輸出信號（TTS 播放）
//  - 但這需要錄音和播放在同一個 AVAudioEngine 中
//  - 這樣 AEC 才能獲取「參考信號」進行回音消除
//

import Foundation
import AVFoundation
import Combine

/// 統一音頻管理器（回音消除核心）
@Observable
final class AudioManager {

    // MARK: - Singleton

    static let shared = AudioManager()

    // MARK: - Properties

    /// 錄音狀態
    private(set) var recordingState: AudioRecordingState = .idle

    /// TTS 播放狀態
    private(set) var isPlayingTTS: Bool = false

    /// 當前播放的 TTS 文本（用於服務器端回音檢測備用）
    private(set) var currentTTSText: String?

    /// ⭐️ 是否暫停發送音頻（TTS 播放時暫停，避免回音被錄到）
    private(set) var isSendingPaused: Bool = false

    /// ⭐️ 防止 onTTSPlaybackComplete 重複調用
    private var hasTriggeredCompletion: Bool = false

    /// 擴音模式
    var isSpeakerMode: Bool = true {
        didSet {
            if oldValue != isSpeakerMode {
                updateOutputRoute()
            }
        }
    }

    // MARK: - 統一 AVAudioEngine（關鍵！）

    /// 單一音頻引擎（錄音和播放共用）
    private let audioEngine = AVAudioEngine()

    /// 播放器節點（TTS 播放用）
    private var playerNode: AVAudioPlayerNode?

    /// EQ 節點（音量放大用）
    private var eqNode: AVAudioUnitEQ?

    /// 混音器節點
    private var mixerNode: AVAudioMixerNode?

    // MARK: - 錄音相關

    private var audioConverter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// 音頻緩衝區
    private var audioBufferCollector: [Data] = []
    private var bufferTimer: Timer?
    private let bufferInterval: TimeInterval = 0.25

    /// 發送計數
    private var sendCount = 0
    private let maxChunkSize = 25600

    // MARK: - TTS 播放相關

    private var audioFile: AVAudioFile?
    private var playbackTimer: Timer?

    /// 音量增益（dB）
    var volumeBoostDB: Float = 6.0

    // MARK: - Combine Publishers

    private let audioDataSubject = PassthroughSubject<Data, Never>()

    var audioDataPublisher: AnyPublisher<Data, Never> {
        audioDataSubject.eraseToAnyPublisher()
    }

    /// TTS 播放完成回調
    var onTTSPlaybackFinished: (() -> Void)?

    // MARK: - Initialization

    private init() {
        setupAudioEngine()
    }

    // MARK: - Audio Engine Setup

    /// 設置統一的音頻引擎
    private func setupAudioEngine() {
        // 創建節點
        playerNode = AVAudioPlayerNode()
        eqNode = AVAudioUnitEQ(numberOfBands: 1)
        mixerNode = AVAudioMixerNode()

        guard let playerNode = playerNode,
              let eqNode = eqNode,
              let mixerNode = mixerNode else {
            print("❌ [AudioManager] 無法創建音頻節點")
            return
        }

        // 附加節點到引擎
        audioEngine.attach(playerNode)
        audioEngine.attach(eqNode)
        audioEngine.attach(mixerNode)

        print("✅ [AudioManager] 音頻節點已附加")
    }

    // MARK: - Audio Session Configuration

    /// 配置 Audio Session（啟用回音消除）
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // ⭐️ 關鍵設置：
        // - .playAndRecord: 同時錄音和播放
        // - .voiceChat: 啟用 Voice Processing I/O（包含 AEC、NS、AGC）
        // - .allowBluetooth: 支持藍牙設備
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try session.setActive(true)

        print("🔇 [AudioManager] Audio Session 配置完成")
        print("   Category: \(session.category.rawValue)")
        print("   Mode: \(session.mode.rawValue) (voiceChat = AEC 啟用)")
        print("   Route: \(session.currentRoute.outputs.first?.portType.rawValue ?? "unknown")")

        // 設置擴音模式
        updateOutputRoute()
    }

    /// 更新輸出路由（擴音/聽筒）
    private func updateOutputRoute() {
        do {
            let session = AVAudioSession.sharedInstance()
            if isSpeakerMode {
                try session.overrideOutputAudioPort(.speaker)
                print("📢 [AudioManager] 擴音模式：揚聲器")
            } else {
                try session.overrideOutputAudioPort(.none)
                print("📱 [AudioManager] 聽筒模式")
            }
        } catch {
            print("❌ [AudioManager] 更新輸出路由失敗: \(error)")
        }
    }

    // MARK: - Recording Methods

    /// 請求麥克風權限
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 開始錄音
    func startRecording() throws {
        guard recordingState != .recording else { return }

        // 配置 Audio Session
        try configureAudioSession()

        // 獲取輸入格式
        let inputNode = audioEngine.inputNode
        inputFormat = inputNode.outputFormat(forBus: 0)

        guard let inputFormat = inputFormat else {
            throw AudioRecordingError.invalidFormat
        }

        // 目標格式：16kHz mono 16-bit PCM
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        outputFormat = AVAudioFormat(streamDescription: &asbd)

        guard let outputFormat = outputFormat else {
            throw AudioRecordingError.invalidFormat
        }

        // 創建轉換器
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)

        guard audioConverter != nil else {
            print("❌ [AudioManager] 無法創建音頻轉換器")
            throw AudioRecordingError.invalidFormat
        }

        // ⭐️ 連接播放節點到混音器
        // 這樣 TTS 播放的聲音會經過同一個 Engine，AEC 可以獲取參考信號
        connectPlaybackNodes()

        // 安裝錄音 Tap
        let bufferSize: AVAudioFrameCount = 4096
        print("🎤 [AudioManager] 安裝音頻 Tap")
        print("   輸入格式: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
        print("   輸出格式: sampleRate=\(outputFormat.sampleRate), channels=\(outputFormat.channelCount)")

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        // 啟動引擎
        try audioEngine.start()
        print("🔊 [AudioManager] 音頻引擎已啟動（統一 Engine，AEC 啟用）")

        // 啟動緩衝區定時器
        startBufferTimer()

        recordingState = .recording
        print("🎙️ [AudioManager] 開始錄音（全雙工模式）")
    }

    /// 連接播放節點
    private func connectPlaybackNodes() {
        guard let playerNode = playerNode,
              let eqNode = eqNode else { return }

        // 獲取輸出格式（使用標準格式）
        let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)

        // 連接：PlayerNode → EQ → MainMixer → Output
        audioEngine.connect(playerNode, to: eqNode, format: outputFormat)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: outputFormat)

        // 配置 EQ
        eqNode.globalGain = volumeBoostDB
        let band = eqNode.bands[0]
        band.filterType = .parametric
        band.frequency = 1000
        band.bandwidth = 2.0
        band.gain = volumeBoostDB
        band.bypass = false

        print("🔊 [AudioManager] 播放節點已連接，音量增益: +\(volumeBoostDB * 2) dB")
    }

    /// 停止錄音
    func stopRecording() {
        guard recordingState == .recording else { return }

        // 停止定時器
        stopBufferTimer()

        // 發送剩餘緩衝區
        flushBuffer()

        // 移除 Tap
        audioEngine.inputNode.removeTap(onBus: 0)

        // 停止引擎
        audioEngine.stop()

        // 重設 Audio Session
        try? resetAudioSession()

        print("⏹️ [AudioManager] 停止錄音 (總計發送 \(sendCount) 次)")
        sendCount = 0
        recordingState = .idle
    }

    // MARK: - TTS Playback Methods

    /// 播放 TTS 音頻
    /// - Parameters:
    ///   - audioData: MP3 音頻數據
    ///   - text: 正在播放的文本（用於回音檢測）
    func playTTS(audioData: Data, text: String? = nil) throws {
        // 停止舊的播放
        stopTTS()

        currentTTSText = text
        isPlayingTTS = true
        hasTriggeredCompletion = false  // 重置完成標誌

        // ⭐️ 暫停發送音頻到服務器（避免回音被錄到）
        isSendingPaused = true
        print("⏸️ [AudioManager] 暫停發送音頻（TTS 播放中，避免回音）")

        // 確保引擎正在運行
        if !audioEngine.isRunning {
            try audioEngine.start()
        }

        // 寫入臨時文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try audioData.write(to: tempURL)

        // 創建音頻文件
        audioFile = try AVAudioFile(forReading: tempURL)

        guard let audioFile = audioFile,
              let playerNode = playerNode else {
            throw TTSError.serverError("無法創建音頻文件")
        }

        // 檢查播放節點是否已連接
        if playerNode.engine == nil {
            connectPlaybackNodes()
        }

        print("▶️ [AudioManager] 播放 TTS")
        print("   文本: \(text?.prefix(30) ?? "unknown")...")
        print("   長度: \(audioFile.length) frames")

        // 調度文件播放
        playerNode.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onTTSPlaybackComplete()
            }
        }

        // 開始播放
        playerNode.play()

        // 監控播放狀態
        startPlaybackMonitor()
    }

    /// TTS 播放完成處理
    private func onTTSPlaybackComplete() {
        // ⭐️ 防止重複調用（scheduleFile 回調和 playbackTimer 都可能觸發）
        guard !hasTriggeredCompletion else {
            print("⚠️ [AudioManager] 忽略重複的播放完成回調")
            return
        }
        hasTriggeredCompletion = true

        print("✅ [AudioManager] TTS 播放完成")
        isPlayingTTS = false
        currentTTSText = nil

        // ⭐️ 恢復發送音頻到服務器
        isSendingPaused = false
        print("▶️ [AudioManager] 恢復發送音頻")

        cleanupPlayback()
        onTTSPlaybackFinished?()
    }

    /// 停止 TTS 播放
    func stopTTS() {
        playbackTimer?.invalidate()
        playbackTimer = nil

        playerNode?.stop()

        if let audioFile = audioFile {
            try? FileManager.default.removeItem(at: audioFile.url)
        }
        audioFile = nil

        isPlayingTTS = false
        currentTTSText = nil

        // ⭐️ 恢復發送音頻
        if isSendingPaused {
            isSendingPaused = false
            print("▶️ [AudioManager] 恢復發送音頻（TTS 已停止）")
        }
    }

    /// 啟動播放監控
    private func startPlaybackMonitor() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self,
                  let node = self.playerNode else {
                timer.invalidate()
                return
            }

            if !node.isPlaying && self.isPlayingTTS {
                timer.invalidate()
                DispatchQueue.main.async {
                    self.onTTSPlaybackComplete()
                }
            }
        }
    }

    /// 清理播放資源
    private func cleanupPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil

        if let audioFile = audioFile {
            try? FileManager.default.removeItem(at: audioFile.url)
        }
        audioFile = nil
    }

    // MARK: - Audio Buffer Processing

    /// 處理音頻緩衝區
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter,
              let outputFormat = outputFormat else { return }

        // 計算輸出緩衝區大小
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        // 轉換音頻
        var hasProvidedData = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvidedData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            return
        }

        // 添加到緩衝區
        if let channelData = outputBuffer.int16ChannelData {
            let frameLength = Int(outputBuffer.frameLength)
            if frameLength > 0 {
                let data = Data(bytes: channelData[0], count: frameLength * 2)
                audioBufferCollector.append(data)
            }
        }
    }

    /// 啟動緩衝區定時器
    private func startBufferTimer() {
        bufferTimer = Timer.scheduledTimer(withTimeInterval: bufferInterval, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }
    }

    /// 停止緩衝區定時器
    private func stopBufferTimer() {
        bufferTimer?.invalidate()
        bufferTimer = nil
    }

    /// 清空並發送緩衝區
    private func flushBuffer() {
        guard !audioBufferCollector.isEmpty else { return }

        // ⭐️ TTS 播放時暫停發送（避免回音被錄到）
        if isSendingPaused {
            // 丟棄緩衝區（TTS 播放中的音頻可能包含回音）
            audioBufferCollector.removeAll()
            return
        }

        // 合併緩衝區
        var combinedData = Data()
        for buffer in audioBufferCollector {
            combinedData.append(buffer)
        }
        audioBufferCollector.removeAll()

        // 分割發送
        var offset = 0
        while offset < combinedData.count {
            let chunkSize = min(maxChunkSize, combinedData.count - offset)
            let chunk = combinedData.subdata(in: offset..<(offset + chunkSize))

            sendCount += 1
            if sendCount == 1 || sendCount % 20 == 0 {
                print("📤 [AudioManager] 發送音頻 #\(sendCount): \(chunk.count) bytes")
            }
            audioDataSubject.send(chunk)

            offset += chunkSize
        }
    }

    /// 重設 Audio Session
    private func resetAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
