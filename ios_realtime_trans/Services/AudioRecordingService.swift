//
//  AudioRecordingService.swift
//  ios_realtime_trans
//
//  音頻錄製服務：使用 AVAudioEngine 捕捉麥克風音頻並轉換為 WebM 格式
//

import Foundation
import AVFoundation
import AudioToolbox
import Combine

/// 音頻錄製狀態
enum AudioRecordingState: Equatable {
    case idle
    case recording
    case error(String)
}

/// 音頻錄製服務協定
protocol AudioRecordingServiceProtocol {
    var recordingState: AudioRecordingState { get }
    var audioDataPublisher: AnyPublisher<Data, Never> { get }

    func requestPermission() async -> Bool
    func startRecording() throws
    func stopRecording()
}

/// 音頻錄製服務實作
@Observable
final class AudioRecordingService: AudioRecordingServiceProtocol {

    // MARK: - Properties

    private(set) var recordingState: AudioRecordingState = .idle

    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    // 音頻緩衝區收集
    private var audioBufferCollector: [Data] = []
    private var bufferTimer: Timer?
    private let bufferInterval: TimeInterval = 0.25  // 每 250ms 發送一次

    // Combine Publishers
    private let audioDataSubject = PassthroughSubject<Data, Never>()

    var audioDataPublisher: AnyPublisher<Data, Never> {
        audioDataSubject.eraseToAnyPublisher()
    }

    // MARK: - Public Methods

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

        // 設定音頻 Session
        try configureAudioSession()

        // 設定音頻格式
        let inputNode = audioEngine.inputNode
        inputFormat = inputNode.outputFormat(forBus: 0)

        guard let inputFormat else {
            throw AudioRecordingError.invalidFormat
        }

        // 目標格式: 16kHz, mono, 16-bit PCM little-endian (與 Google Speech LINEAR16 匹配)
        // 使用 AudioStreamBasicDescription 確保格式正確
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

        guard let outputFormat else {
            throw AudioRecordingError.invalidFormat
        }

        // 建立轉換器
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)

        guard audioConverter != nil else {
            print("❌ 無法建立音頻轉換器")
            print("   輸入格式: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount), format=\(inputFormat.commonFormat.rawValue)")
            print("   輸出格式: sampleRate=\(outputFormat.sampleRate), channels=\(outputFormat.channelCount), format=\(outputFormat.commonFormat.rawValue)")
            throw AudioRecordingError.invalidFormat
        }

        // 安裝 Tap 來捕捉音頻
        let bufferSize: AVAudioFrameCount = 4096
        print("🎤 安裝音頻 Tap")
        print("   輸入格式: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount), format=\(inputFormat.commonFormat.rawValue)")
        print("   輸出格式: sampleRate=\(outputFormat.sampleRate), channels=\(outputFormat.channelCount)")

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        // 啟動音頻引擎
        try audioEngine.start()
        print("🔊 音頻引擎已啟動")

        // 啟動定時發送器
        startBufferTimer()

        recordingState = .recording
        print("🎙️ 開始錄音")
    }

    /// 停止錄音
    func stopRecording() {
        guard recordingState == .recording else { return }

        // 停止定時器
        stopBufferTimer()

        // 發送剩餘緩衝區
        flushBuffer()

        // 停止音頻引擎
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // 重設音頻 Session
        try? resetAudioSession()

        print("⏹️ 停止錄音 (總計發送 \(sendCount) 次)")
        sendCount = 0
        recordingState = .idle
    }

    // MARK: - Private Methods

    /// 設定音頻 Session
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // ⭐️ 使用 .voiceChat mode 啟用回音消除
        // - Echo Cancellation: 消除揚聲器播放的聲音被麥克風收音
        // - Noise Suppression: 抑制背景噪音
        // - Automatic Gain Control: 自動調整麥克風增益
        // 📱 移除 .defaultToSpeaker，改用聽筒（earpiece）輸出
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try session.setActive(true)

        print("🔇 [Audio Session] Echo Cancellation enabled (mode: .voiceChat)")
        print("📱 [Audio Session] Output route: Receiver (earpiece)")
    }

    /// 重設音頻 Session
    private func resetAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 處理音頻緩衝區
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter,
              let outputFormat else { return }

        // 計算輸出緩衝區大小
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        // 使用 inputBlock 追蹤是否已經提供過數據
        var hasProvidedData = false

        // 轉換音頻格式
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasProvidedData {
                // 已經提供過數據，告知沒有更多數據
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            print("❌ 音頻轉換錯誤: status=\(status.rawValue), error=\(error?.localizedDescription ?? "nil")")
            return
        }

        // 將轉換後的音頻數據添加到緩衝區
        if let channelData = outputBuffer.int16ChannelData {
            let frameLength = Int(outputBuffer.frameLength)
            if frameLength > 0 {
                let data = Data(bytes: channelData[0], count: frameLength * 2)
                audioBufferCollector.append(data)

                // Debug: 檢查音頻數據是否有效（不全是靜音）
                let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
                let maxSample = samples.max() ?? 0
                let minSample = samples.min() ?? 0
                if abs(maxSample) > 100 || abs(minSample) > 100 {
                    // 有音頻信號
                } else if audioBufferCollector.count == 1 {
                    print("⚠️ 音頻似乎是靜音 (max=\(maxSample), min=\(minSample))")
                }
            }
        } else {
            print("⚠️ outputBuffer.int16ChannelData 為 nil")
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

    /// 發送計數器
    private var sendCount = 0

    /// Google Speech API 最大 chunk 大小
    private let maxChunkSize = 25600

    /// 清空並發送緩衝區
    private func flushBuffer() {
        guard !audioBufferCollector.isEmpty else { return }

        // 合併所有緩衝區
        var combinedData = Data()
        for buffer in audioBufferCollector {
            combinedData.append(buffer)
        }
        audioBufferCollector.removeAll()

        // 分割成最大 25600 bytes 的 chunks
        var offset = 0
        while offset < combinedData.count {
            let chunkSize = min(maxChunkSize, combinedData.count - offset)
            let chunk = combinedData.subdata(in: offset..<(offset + chunkSize))

            sendCount += 1
            // 只在第 1 次和每 20 次輸出 log
            if sendCount == 1 || sendCount % 20 == 0 {
                print("📤 發送音頻 #\(sendCount): \(chunk.count) bytes")
            }
            audioDataSubject.send(chunk)

            offset += chunkSize
        }
    }

    /// 建立 WebM 格式音頻數據
    /// 注意：這是簡化版本，實際 WebM 需要完整的容器格式
    /// 但 Chirp3 的 autoDecodingConfig 可以處理 raw PCM
    private func createWebMAudioData(from pcmData: Data) -> Data {
        // 這裡我們直接發送 PCM 數據，因為 server 的 autoDecodingConfig
        // 會自動檢測音頻格式
        return pcmData
    }
}

// MARK: - Errors

enum AudioRecordingError: LocalizedError {
    case permissionDenied
    case invalidFormat
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "麥克風權限被拒絕"
        case .invalidFormat:
            return "無效的音頻格式"
        case .engineStartFailed:
            return "無法啟動音頻引擎"
        }
    }
}
