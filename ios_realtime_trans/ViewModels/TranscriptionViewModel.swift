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

    // MARK: - Configuration

    /// 伺服器 URL（Cloud Run 部署的服務）
    var serverURL: String = "chirp3-ios-api-1027448899164.asia-east1.run.app"

    // MARK: - Private Properties

    private let webSocketService = WebSocketService()
    private let audioRecordingService = AudioRecordingService()

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
        let granted = await audioRecordingService.requestPermission()
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

        // 開始錄音
        do {
            try audioRecordingService.startRecording()
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
        audioRecordingService.stopRecording()
        webSocketService.disconnect()
        status = .disconnected

        // 清除 interim
        interimTranscript = nil
    }

    /// 設定 Combine 訂閱
    private func setupSubscriptions() {
        // 訂閱音頻數據
        audioRecordingService.audioDataPublisher
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
    }

    /// 處理轉錄結果
    private func handleTranscript(_ transcript: TranscriptMessage) {
        if transcript.isFinal {
            // 最終結果：添加到列表
            transcripts.insert(transcript, at: 0)
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
        if let index = transcripts.firstIndex(where: { $0.text == sourceText }) {
            transcripts[index].translation = translatedText
        } else if interimTranscript?.text == sourceText {
            interimTranscript?.translation = translatedText
        }
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
