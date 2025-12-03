//
//  WebSocketService.swift
//  ios_realtime_trans
//
//  WebSocket 服務：連接 Chirp3 轉錄伺服器
//

import Foundation
import Combine

/// WebSocket 連接狀態
enum WebSocketConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// WebSocket 服務協定
protocol WebSocketServiceProtocol {
    var connectionState: WebSocketConnectionState { get }
    var transcriptPublisher: AnyPublisher<TranscriptMessage, Never> { get }
    var translationPublisher: AnyPublisher<(String, String), Never> { get }
    var errorPublisher: AnyPublisher<String, Never> { get }

    func connect(serverURL: String, sourceLang: Language, targetLang: Language)
    func disconnect()
    func sendAudio(data: Data)
}

/// WebSocket 服務實作
@Observable
final class WebSocketService: NSObject, WebSocketServiceProtocol {

    // MARK: - Properties

    private(set) var connectionState: WebSocketConnectionState = .disconnected

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// ⭐️ 心跳計時器（保持連接存活）
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 15.0  // 每 15 秒發送一次 ping

    // Combine Publishers
    private let transcriptSubject = PassthroughSubject<TranscriptMessage, Never>()
    private let translationSubject = PassthroughSubject<(String, String), Never>()
    private let errorSubject = PassthroughSubject<String, Never>()

    var transcriptPublisher: AnyPublisher<TranscriptMessage, Never> {
        transcriptSubject.eraseToAnyPublisher()
    }

    var translationPublisher: AnyPublisher<(String, String), Never> {
        translationSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<String, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Public Methods

    /// 連接到 WebSocket 伺服器
    func connect(serverURL: String, sourceLang: Language, targetLang: Language) {
        // 如果已經在連接中，不要重複連接
        if case .connecting = connectionState {
            print("⚠️ 已經在連接中，忽略")
            return
        }

        // 清理舊連接（但不改變狀態）
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        connectionState = .connecting

        // 建立 WebSocket URL
        var urlString = serverURL
        if !urlString.hasPrefix("ws://") && !urlString.hasPrefix("wss://") {
            // Cloud Run 使用 HTTPS，所以 WebSocket 用 wss://
            // 本地開發 (localhost) 使用 ws://
            if urlString.contains("localhost") || urlString.contains("127.0.0.1") || urlString.contains("192.168.") {
                urlString = "ws://\(urlString)"
            } else {
                urlString = "wss://\(urlString)"
            }
        }

        // 添加語言參數和客戶端類型（iOS 發送 raw PCM，需要明確的解碼配置）
        urlString += "/transcribe?sourceLang=\(sourceLang.rawValue)&targetLang=\(targetLang.rawValue)&client=ios"

        guard let url = URL(string: urlString) else {
            connectionState = .error("無效的伺服器 URL")
            errorSubject.send("無效的伺服器 URL")
            return
        }

        print("🔗 連接到 WebSocket: \(url)")

        // 建立 URLSession
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        // 建立 WebSocket Task
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // 開始接收訊息
        receiveMessage()
    }

    /// 斷開連接
    func disconnect() {
        // 停止心跳
        stopPingTimer()

        if wsSendCount > 0 {
            print("📊 WebSocket 總計發送: \(wsSendCount) 次音頻")
        }
        wsSendCount = 0
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
    }

    // MARK: - 心跳機制

    /// 啟動心跳計時器
    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        print("💓 心跳計時器已啟動（每 \(Int(pingInterval)) 秒）")
    }

    /// 停止心跳計時器
    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// 發送 ping
    private func sendPing() {
        guard connectionState == .connected else { return }

        webSocketTask?.sendPing { [weak self] error in
            if let error {
                print("❌ Ping 失敗: \(error.localizedDescription)")
                // Ping 失敗可能表示連接已斷開
                Task { @MainActor in
                    self?.connectionState = .error("連接已斷開")
                    self?.errorSubject.send("連接已斷開")
                }
            } else {
                print("💓 Ping 成功")
            }
        }
    }

    /// 發送計數器
    private var wsSendCount = 0

    /// ⭐️ 發送結束語句信號（PTT 放開時調用，強制 Chirp3 輸出結果）
    func sendEndUtterance() {
        guard connectionState == .connected else { return }

        let endMessage = ["type": "end_utterance"]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: endMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { error in
                    if let error {
                        print("❌ 發送結束信號錯誤: \(error.localizedDescription)")
                    } else {
                        print("🔚 已發送結束語句信號")
                    }
                }
            }
        } catch {
            print("❌ 編碼結束信號錯誤: \(error)")
        }
    }

    /// 發送音頻數據
    func sendAudio(data: Data) {
        guard connectionState == .connected else {
            if wsSendCount == 0 {
                print("⚠️ WebSocket 未連接，無法發送音頻")
            }
            return
        }

        let base64String = data.base64EncodedString()
        let audioMessage = AudioMessage(data: base64String)
        wsSendCount += 1

        do {
            let jsonData = try JSONEncoder().encode(audioMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { [weak self] error in
                    if let error {
                        print("❌ 發送音頻錯誤: \(error.localizedDescription)")
                        self?.errorSubject.send("發送音頻失敗")
                    }
                }
            }
        } catch {
            print("❌ 編碼音頻訊息錯誤: \(error)")
        }
    }

    // MARK: - Private Methods

    /// 持續接收訊息
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                // 繼續接收下一則訊息
                self.receiveMessage()

            case .failure(let error):
                print("❌ WebSocket 接收錯誤: \(error.localizedDescription)")
                self.connectionState = .error(error.localizedDescription)
                self.errorSubject.send(error.localizedDescription)
            }
        }
    }

    /// 處理收到的訊息
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerResponse(text)

        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerResponse(text)
            }

        @unknown default:
            break
        }
    }

    /// 解析伺服器回應
    private func parseServerResponse(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(ServerTranscriptResponse.self, from: data)

            switch response.type {
            case "transcript":
                guard let transcriptText = response.text else { return }

                let transcript = TranscriptMessage(
                    text: transcriptText,
                    isFinal: response.isFinal ?? false,
                    confidence: response.confidence ?? 0,
                    language: response.language,
                    converted: response.converted ?? false,
                    originalText: response.originalText,
                    speakerTag: response.speakerTag
                )

                transcriptSubject.send(transcript)

                // ⭐️ 打印延遲統計
                let latencyStr: String
                if let latency = response.latency?.transcriptMs {
                    latencyStr = " ⏱️\(latency)ms"
                } else {
                    latencyStr = ""
                }

                if transcript.isFinal {
                    print("✅ [\(response.language ?? "?")] \(transcriptText)\(latencyStr)")
                } else {
                    print("⋯ [interim] \(transcriptText)")
                }

            case "translation":
                guard let translatedText = response.text,
                      let sourceText = response.sourceText else { return }

                translationSubject.send((sourceText, translatedText))

                // ⭐️ 打印延遲統計
                let latencyStr: String
                if let latency = response.latency?.translationMs {
                    latencyStr = " ⏱️\(latency)ms"
                } else {
                    latencyStr = ""
                }
                print("🌐 翻譯: \(translatedText)\(latencyStr)")

            case "error":
                let errorMessage = response.message ?? "未知錯誤"
                errorSubject.send(errorMessage)
                print("❌ 伺服器錯誤: \(errorMessage)")

            default:
                print("⚠️ 未知訊息類型: \(response.type)")
            }

        } catch {
            print("❌ 解析伺服器回應錯誤: \(error)")
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            print("✅ WebSocket 連接成功")
            self.connectionState = .connected
            // ⭐️ 連接成功後啟動心跳
            self.startPingTimer()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            print("📱 WebSocket 連接關閉 (code: \(closeCode.rawValue))")
            self.connectionState = .disconnected
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            if let error {
                print("❌ URLSession 錯誤: \(error.localizedDescription)")
                self.connectionState = .error(error.localizedDescription)
                self.errorSubject.send(error.localizedDescription)
            }
        }
    }
}
