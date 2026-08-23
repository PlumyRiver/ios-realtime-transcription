//
//  GPTRealtime2Service.swift
//  ios_realtime_trans
//
//  GPT-Realtime-2 voice interpretation with visible input/output transcripts.
//

import Foundation
import Combine
import FirebaseAuth

struct GPTRealtime2OutputTranscript: Sendable {
    let responseId: String
    let sourceItemId: String
    let sourceMessageId: UUID?
    let sourceText: String
    let text: String
    let isFinal: Bool
}

struct GPTRealtime2Usage: Sendable {
    let id: String
    let category: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let textInputTokens: Int
    let audioInputTokens: Int
    let cachedInputTokens: Int
    let textOutputTokens: Int
    let audioOutputTokens: Int
    let audioDurationMs: Int
    let costUSD: Double
}

@Observable
final class GPTRealtime2Service: NSObject, WebSocketServiceProtocol, URLSessionWebSocketDelegate {
    private(set) var connectionState: WebSocketConnectionState = .disconnected
    private(set) var hasActiveResponse = false

    private let transcriptSubject = PassthroughSubject<TranscriptMessage, Never>()
    private let translationSubject = PassthroughSubject<(String, String), Never>()
    private let segmentedTranslationSubject = PassthroughSubject<(String, [TranslationSegment]), Never>()
    private let correctionSubject = PassthroughSubject<(String, String), Never>()
    private let errorSubject = PassthroughSubject<String, Never>()
    private let outputTranscriptSubject = PassthroughSubject<GPTRealtime2OutputTranscript, Never>()
    private let outputAudioSubject = PassthroughSubject<Data, Never>()
    private let outputAudioCompletedSubject = PassthroughSubject<String, Never>()
    private let usageSubject = PassthroughSubject<GPTRealtime2Usage, Never>()

    var transcriptPublisher: AnyPublisher<TranscriptMessage, Never> { transcriptSubject.eraseToAnyPublisher() }
    var translationPublisher: AnyPublisher<(String, String), Never> { translationSubject.eraseToAnyPublisher() }
    var segmentedTranslationPublisher: AnyPublisher<(String, [TranslationSegment]), Never> { segmentedTranslationSubject.eraseToAnyPublisher() }
    var correctionPublisher: AnyPublisher<(String, String), Never> { correctionSubject.eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<String, Never> { errorSubject.eraseToAnyPublisher() }
    var outputTranscriptPublisher: AnyPublisher<GPTRealtime2OutputTranscript, Never> { outputTranscriptSubject.eraseToAnyPublisher() }
    var outputAudioPublisher: AnyPublisher<Data, Never> { outputAudioSubject.eraseToAnyPublisher() }
    var outputAudioCompletedPublisher: AnyPublisher<String, Never> { outputAudioCompletedSubject.eraseToAnyPublisher() }
    var usagePublisher: AnyPublisher<GPTRealtime2Usage, Never> { usageSubject.eraseToAnyPublisher() }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private var sourceLanguage: Language = .zh
    private var targetLanguage: Language = .en
    private var inputTextByItem: [String: String] = [:]
    private var inputIdByItem: [String: UUID] = [:]
    private var outputTextByResponse: [String: String] = [:]
    private var sourceItemByResponse: [String: String] = [:]
    private var activeResponseId = ""
    private var activeOutputItemId = ""
    private var publishedBillingIds: Set<String> = []
    private let resampler = PCM16Resampler(inputRate: 16_000, outputRate: 24_000)

    func connect(serverURL: String, sourceLang: Language, targetLang: Language) {
        guard connectionState != .connecting, connectionState != .connected else { return }
        disconnect()
        connectionState = .connecting
        sourceLanguage = sourceLang
        targetLanguage = targetLang
        resetTurnState()

        Task { [weak self] in
            guard let self else { return }
            guard let token = await self.currentFirebaseIDToken() else {
                await MainActor.run {
                    self.failConnection("無法取得登入憑證")
                }
                return
            }
            guard let url = self.makeURL(serverURL: serverURL, sourceLang: sourceLang, targetLang: targetLang) else {
                await MainActor.run {
                    self.failConnection("GPT Live 2 伺服器網址無效")
                }
                return
            }
            await MainActor.run {
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 30
                configuration.waitsForConnectivity = true
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
                self.urlSession = session
                let task = session.webSocketTask(with: url, protocols: ["firebase-auth", token])
                self.webSocketTask = task
                task.resume()
                self.receiveNextMessage()
            }
        }
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
        resetTurnState()
    }

    func sendAudio(data: Data) {
        guard connectionState == .connected, !data.isEmpty else { return }
        let pcm24k = resampler.process(data)
        guard !pcm24k.isEmpty else { return }
        sendJSON([
            "type": "audio.append",
            "audio": pcm24k.base64EncodedString()
        ])
    }

    func sendEndUtterance() {
        guard connectionState == .connected else { return }
        sendJSON(["type": "audio.end"])
    }

    func cancelResponse() {
        guard connectionState == .connected else { return }
        sendJSON(["type": "response.cancel"])
    }

    func interruptCurrentResponse(audioEndMs: Int) {
        guard connectionState == .connected else { return }
        sendJSON([
            "type": "response.interrupt",
            "responseId": activeResponseId,
            "itemId": activeOutputItemId,
            "audioEndMs": max(0, audioEndMs)
        ])
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        startPingTimer()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard connectionState != .disconnected else { return }
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        failConnection("GPT Live 2 連線中斷\(reasonText.isEmpty ? "" : "：\(reasonText)")")
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    if self.connectionState != .disconnected {
                        self.receiveNextMessage()
                    }
                case .failure(let error):
                    self.failConnection("GPT Live 2 接收失敗：\(error.localizedDescription)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "ready":
            connectionState = .connected
        case "input.transcript.delta":
            handleInputDelta(object)
        case "input.transcript.completed":
            handleInputCompleted(object)
            publishBilling(from: object, fallbackId: (object["itemId"] as? String) ?? UUID().uuidString)
        case "input.transcript.failed":
            errorSubject.send((object["message"] as? String) ?? "輸入語音轉錄失敗")
        case "output.transcript.delta":
            handleOutputTranscript(object, isFinal: false)
        case "output.transcript.completed":
            handleOutputTranscript(object, isFinal: true)
        case "output.audio.delta":
            activeResponseId = (object["responseId"] as? String) ?? activeResponseId
            activeOutputItemId = (object["itemId"] as? String) ?? activeOutputItemId
            if let encoded = object["audio"] as? String,
               let audio = Data(base64Encoded: encoded),
               !audio.isEmpty {
                outputAudioSubject.send(audio)
            }
        case "output.audio.completed":
            outputAudioCompletedSubject.send((object["responseId"] as? String) ?? "")
        case "output.audio.interrupted":
            outputAudioCompletedSubject.send("interrupted")
        case "response.started":
            activeResponseId = (object["responseId"] as? String) ?? ""
            activeOutputItemId = ""
            let sourceItemId = ((object["sourceItemId"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !activeResponseId.isEmpty, !sourceItemId.isEmpty {
                sourceItemByResponse[activeResponseId] = sourceItemId
                _ = messageID(for: sourceItemId)
            }
            hasActiveResponse = true
        case "response.completed":
            let responseId = (object["responseId"] as? String) ?? UUID().uuidString
            publishBilling(from: object, fallbackId: responseId)
            if responseId == activeResponseId {
                activeResponseId = ""
            }
            sourceItemByResponse.removeValue(forKey: responseId)
            hasActiveResponse = false
        case "error":
            errorSubject.send((object["message"] as? String) ?? "GPT Live 2 發生錯誤")
        default:
            break
        }
    }

    private func handleInputDelta(_ object: [String: Any]) {
        let itemId = (object["itemId"] as? String) ?? UUID().uuidString
        let delta = (object["delta"] as? String) ?? ""
        guard !delta.isEmpty else { return }
        inputTextByItem[itemId, default: ""] += delta
        let text = inputTextByItem[itemId] ?? ""
        let id = messageID(for: itemId)
        transcriptSubject.send(TranscriptMessage(
            id: id,
            text: text,
            isFinal: false,
            confidence: 1,
            language: sourceLanguage.rawValue
        ))
    }

    private func handleInputCompleted(_ object: [String: Any]) {
        let itemId = (object["itemId"] as? String) ?? UUID().uuidString
        let transcript = ((object["transcript"] as? String) ?? inputTextByItem[itemId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        inputTextByItem[itemId] = transcript
        let id = messageID(for: itemId)
        let detectedLanguage = detectedLanguageCode(object) ?? sourceLanguage.rawValue
        transcriptSubject.send(TranscriptMessage(
            id: id,
            text: transcript,
            isFinal: true,
            confidence: 1,
            language: detectedLanguage
        ))
    }

    private func handleOutputTranscript(_ object: [String: Any], isFinal: Bool) {
        let responseId = (object["responseId"] as? String) ?? UUID().uuidString
        let sourceItemId = ((object["sourceItemId"] as? String) ?? sourceItemByResponse[responseId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceItemId.isEmpty {
            sourceItemByResponse[responseId] = sourceItemId
        }
        if isFinal {
            let completed = ((object["transcript"] as? String) ?? outputTextByResponse[responseId] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !completed.isEmpty else { return }
            outputTextByResponse[responseId] = completed
        } else {
            let delta = (object["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return }
            outputTextByResponse[responseId, default: ""] += delta
        }
        let source = ((object["sourceTranscript"] as? String) ?? inputTextByItem[sourceItemId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        outputTranscriptSubject.send(GPTRealtime2OutputTranscript(
            responseId: responseId,
            sourceItemId: sourceItemId,
            sourceMessageId: sourceItemId.isEmpty ? nil : messageID(for: sourceItemId),
            sourceText: source,
            text: outputTextByResponse[responseId] ?? "",
            isFinal: isFinal
        ))
        if isFinal {
            outputTextByResponse.removeValue(forKey: responseId)
        }
    }

    private func detectedLanguageCode(_ object: [String: Any]) -> String? {
        guard let languages = object["languages"] as? [[String: Any]] else { return nil }
        return languages.compactMap { $0["code"] as? String }.first
    }

    private func messageID(for itemId: String) -> UUID {
        if let id = inputIdByItem[itemId] { return id }
        let id = UUID()
        inputIdByItem[itemId] = id
        return id
    }

    private func publishBilling(from object: [String: Any], fallbackId: String) {
        guard let billing = object["billing"] as? [String: Any] else { return }
        let category = (billing["category"] as? String) ?? "gpt-realtime-2"
        let id = "\(category):\(fallbackId)"
        guard publishedBillingIds.insert(id).inserted else { return }
        usageSubject.send(GPTRealtime2Usage(
            id: fallbackId,
            category: category,
            model: (billing["model"] as? String) ?? category,
            inputTokens: integer(billing["inputTokens"]),
            outputTokens: integer(billing["outputTokens"]),
            textInputTokens: integer(billing["textInputTokens"]),
            audioInputTokens: integer(billing["audioInputTokens"]),
            cachedInputTokens: integer(billing["cachedInputTokens"]),
            textOutputTokens: integer(billing["textOutputTokens"]),
            audioOutputTokens: integer(billing["audioOutputTokens"]),
            audioDurationMs: integer(billing["audioDurationMs"]),
            costUSD: max(0, (billing["costUSD"] as? NSNumber)?.doubleValue ?? 0)
        ))
    }

    private func integer(_ value: Any?) -> Int {
        max(0, (value as? NSNumber)?.intValue ?? 0)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.errorSubject.send("GPT Live 2 傳送失敗：\(error.localizedDescription)")
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error {
                    DispatchQueue.main.async {
                        self?.errorSubject.send("GPT Live 2 心跳失敗：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func failConnection(_ message: String) {
        connectionState = .error(message)
        errorSubject.send(message)
    }

    private func resetTurnState() {
        inputTextByItem.removeAll()
        inputIdByItem.removeAll()
        outputTextByResponse.removeAll()
        sourceItemByResponse.removeAll()
        activeResponseId = ""
        activeOutputItemId = ""
        hasActiveResponse = false
        publishedBillingIds.removeAll()
        resampler.reset()
    }

    private func makeURL(serverURL: String, sourceLang: Language, targetLang: Language) -> URL? {
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("https://") {
            value = "wss://" + value.dropFirst(8)
        } else if value.hasPrefix("http://") {
            value = "ws://" + value.dropFirst(7)
        } else if !value.hasPrefix("ws://") && !value.hasPrefix("wss://") {
            let local = value.contains("localhost") || value.contains("127.0.0.1") || value.contains("192.168.")
            value = "\(local ? "ws" : "wss")://\(value)"
        }
        guard var components = URLComponents(string: value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/ios/gpt-realtime-2") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "sourceLang", value: sourceLang.rawValue),
            URLQueryItem(name: "targetLang", value: targetLang.rawValue)
        ]
        return components.url
    }

    private func currentFirebaseIDToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return await withCheckedContinuation { continuation in
            user.getIDTokenForcingRefresh(false) { token, _ in
                continuation.resume(returning: token)
            }
        }
    }
}

private final class PCM16Resampler {
    private let ratio: Double
    private var previousSample: Int16?
    private var sourcePosition: Double = 0

    init(inputRate: Double, outputRate: Double) {
        ratio = outputRate / inputRate
    }

    func process(_ data: Data) -> Data {
        guard data.count >= 2 else { return Data() }
        var samples = data.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        if let previousSample {
            samples.insert(previousSample, at: 0)
        }
        guard samples.count >= 2 else {
            previousSample = samples.last
            return Data()
        }

        var output: [Int16] = []
        output.reserveCapacity(Int(Double(samples.count) * ratio) + 2)
        let step = 1.0 / ratio
        while sourcePosition < Double(samples.count - 1) {
            let lower = Int(sourcePosition)
            let fraction = sourcePosition - Double(lower)
            let first = Double(samples[lower])
            let second = Double(samples[lower + 1])
            let interpolated = first + (second - first) * fraction
            output.append(Int16(clamping: Int(interpolated.rounded())))
            sourcePosition += step
        }
        sourcePosition -= Double(samples.count - 1)
        previousSample = samples.last

        return output.withUnsafeBytes { Data($0) }
    }

    func reset() {
        previousSample = nil
        sourcePosition = 0
    }
}
