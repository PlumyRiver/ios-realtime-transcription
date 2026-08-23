//
//  BillingService.swift
//  ios_realtime_trans
//
//  計費服務 - 追蹤 STT、LLM、TTS 用量並計算費用
//

import Foundation
import FirebaseFirestore

// MARK: - 計費定價常量

/// 計費定價配置
struct BillingPricing {
    // STT (Speech-to-Text): $0.5 USD per hour，按秒精度計費
    static let sttPricePerHour: Double = 0.5
    static let sttPricePerSecond: Double = sttPricePerHour / 3600.0  // ≈ $0.000139/秒

    // LLM 翻譯: Input $0.35 USD/M tokens, Output $0.75 USD/M tokens
    static let llmInputPricePerMToken: Double = 0.35
    static let llmOutputPricePerMToken: Double = 0.75
    static let llmInputPricePerToken: Double = llmInputPricePerMToken / 1_000_000.0
    static let llmOutputPricePerToken: Double = llmOutputPricePerMToken / 1_000_000.0

    // Agent (Claude Sonnet): Input $3.00 USD/M tokens, Output $15.00 USD/M tokens
    static let agentInputPricePerMToken: Double = 3.00
    static let agentOutputPricePerMToken: Double = 15.00
    static let agentCacheReadInputPricePerMToken: Double = 0.30
    static let agentCacheCreationInputPricePerMToken: Double = 3.75
    static let agentInputPricePerToken: Double = agentInputPricePerMToken / 1_000_000.0
    static let agentOutputPricePerToken: Double = agentOutputPricePerMToken / 1_000_000.0
    static let agentCacheReadInputPricePerToken: Double = agentCacheReadInputPricePerMToken / 1_000_000.0
    static let agentCacheCreationInputPricePerToken: Double = agentCacheCreationInputPricePerMToken / 1_000_000.0

    // TTS (Azure): $16 USD per million characters (Neural voices)
    // 參考: https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/
    static let ttsPricePerMChar: Double = 16.0
    static let ttsPricePerChar: Double = ttsPricePerMChar / 1_000_000.0  // $0.000016/character

    // 額度換算: 1 USD = 100,000 額度 (1 額度 = $0.00001 USD)
    static let creditsPerUSD: Double = 100000.0
    static let usdPerCredit: Double = 1.0 / creditsPerUSD

    static func agentCostUSD(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        model: String
    ) -> Double {
        let normalizedModel = model.lowercased()
        let inputPrice: Double
        let outputPrice: Double
        let cacheReadPrice: Double
        let cacheCreationPrice: Double

        if normalizedModel.contains("claude-sonnet") {
            inputPrice = agentInputPricePerToken
            outputPrice = agentOutputPricePerToken
            cacheReadPrice = agentCacheReadInputPricePerToken
            cacheCreationPrice = agentCacheCreationInputPricePerToken
        } else {
            inputPrice = agentInputPricePerToken
            outputPrice = agentOutputPricePerToken
            cacheReadPrice = agentCacheReadInputPricePerToken
            cacheCreationPrice = agentCacheCreationInputPricePerToken
        }

        let uncachedInputTokens = max(0, inputTokens - cacheReadInputTokens - cacheCreationInputTokens)
        return Double(uncachedInputTokens) * inputPrice +
            Double(cacheReadInputTokens) * cacheReadPrice +
            Double(cacheCreationInputTokens) * cacheCreationPrice +
            Double(outputTokens) * outputPrice
    }
}

// MARK: - 用量追蹤結構

/// 單次會話的用量統計
struct SessionUsage {
    // STT 用量
    var sttDurationSeconds: Double = 0

    // GPT Live 2 combines realtime reasoning, audio generation, and the
    // separately billed GPT Transcribe input transcript.
    var gptRealtimeInputTokens: Int = 0
    var gptRealtimeOutputTokens: Int = 0
    var gptRealtimeTextInputTokens: Int = 0
    var gptRealtimeAudioInputTokens: Int = 0
    var gptRealtimeCachedInputTokens: Int = 0
    var gptRealtimeTextOutputTokens: Int = 0
    var gptRealtimeAudioOutputTokens: Int = 0
    var gptTranscribeDurationSeconds: Double = 0
    var gptRealtimeCostUSD: Double = 0

    // LLM 翻譯用量
    var llmInputTokens: Int = 0
    var llmOutputTokens: Int = 0

    // Agent 用量
    var agentInputTokens: Int = 0
    var agentOutputTokens: Int = 0
    var agentCacheReadInputTokens: Int = 0
    var agentCacheCreationInputTokens: Int = 0
    var agentBilledCostUSD: Double = 0

    // TTS 用量（按字符數計算）
    var ttsCharCount: Int = 0

    // 計算各項費用 (USD)
    var sttCostUSD: Double {
        return sttDurationSeconds * BillingPricing.sttPricePerSecond
    }

    var llmCostUSD: Double {
        let inputCost = Double(llmInputTokens) * BillingPricing.llmInputPricePerToken
        let outputCost = Double(llmOutputTokens) * BillingPricing.llmOutputPricePerToken
        return inputCost + outputCost
    }

    var agentCostUSD: Double {
        return agentBilledCostUSD
    }

    var ttsCostUSD: Double {
        return Double(ttsCharCount) * BillingPricing.ttsPricePerChar
    }

    var totalCostUSD: Double {
        return sttCostUSD + gptRealtimeCostUSD + llmCostUSD + agentCostUSD + ttsCostUSD
    }

    var totalTokenCount: Int {
        return gptRealtimeInputTokens + gptRealtimeOutputTokens +
            llmInputTokens + llmOutputTokens + agentInputTokens + agentOutputTokens
    }

    // 轉換為額度消耗
    var totalCreditsUsed: Int {
        return Int(ceil(totalCostUSD * BillingPricing.creditsPerUSD))
    }

    // 轉換為 Firestore 文檔
    func toFirestoreData() -> [String: Any] {
        return [
            "sttDurationSeconds": sttDurationSeconds,
            "gptRealtimeInputTokens": gptRealtimeInputTokens,
            "gptRealtimeOutputTokens": gptRealtimeOutputTokens,
            "gptRealtimeTextInputTokens": gptRealtimeTextInputTokens,
            "gptRealtimeAudioInputTokens": gptRealtimeAudioInputTokens,
            "gptRealtimeCachedInputTokens": gptRealtimeCachedInputTokens,
            "gptRealtimeTextOutputTokens": gptRealtimeTextOutputTokens,
            "gptRealtimeAudioOutputTokens": gptRealtimeAudioOutputTokens,
            "gptTranscribeDurationSeconds": gptTranscribeDurationSeconds,
            "gptRealtimeCostUSD": gptRealtimeCostUSD,
            "llmInputTokens": llmInputTokens,
            "llmOutputTokens": llmOutputTokens,
            "agentInputTokens": agentInputTokens,
            "agentOutputTokens": agentOutputTokens,
            "agentCacheReadInputTokens": agentCacheReadInputTokens,
            "agentCacheCreationInputTokens": agentCacheCreationInputTokens,
            "ttsCharCount": ttsCharCount,
            "sttCostUSD": sttCostUSD,
            "llmCostUSD": llmCostUSD,
            "agentCostUSD": agentCostUSD,
            "ttsCostUSD": ttsCostUSD,
            "totalTokens": totalTokenCount,
            "totalCostUSD": totalCostUSD,
            "totalCreditsUsed": totalCreditsUsed
        ]
    }
}

// MARK: - 計費服務

@Observable
final class BillingService {

    // MARK: - Singleton

    static let shared = BillingService()

    // MARK: - Properties

    /// 當前會話的用量統計
    private(set) var currentUsage = SessionUsage()

    /// STT 開始時間（用於計算持續時間）
    private var sttStartTime: Date?

    /// 是否正在計費中
    private(set) var isBilling: Bool = false

    /// Firestore 引用
    private let db: Firestore

    /// ⭐️ STT 即時扣款計時器（每秒扣款一次）
    private var sttBillingTimer: Timer?

    /// ⭐️ 上次 STT 扣款時間（用於計算間隔）
    private var lastSTTBillingTime: Date?

    /// ⭐️ PTT 模式：是否正在發送音訊（只有發送時才計費）
    private(set) var isAudioSending: Bool = false

    /// ⭐️ STT 計費開關（經濟模式用 Apple STT 免費，不計費）
    private(set) var isSTTBillingEnabled: Bool = false

    /// ⭐️ 額度耗盡回調（通知 ViewModel 停止錄音）
    var onCreditsExhausted: (() -> Void)?

    /// ⭐️ 本次 App 使用的累計消耗額度（從 App 啟動開始計算）
    private(set) var sessionTotalCreditsUsed: Int = 0

    /// ⭐️ 各項目累計消耗額度（用於顯示消耗組成）
    private(set) var sessionSTTCreditsUsed: Int = 0
    private(set) var sessionGPTRealtimeCreditsUsed: Int = 0
    private var currentSessionGPTRealtimeCreditsDeducted: Int = 0
    private(set) var sessionLLMCreditsUsed: Int = 0
    private(set) var sessionAgentCreditsUsed: Int = 0
    private(set) var sessionTTSCreditsUsed: Int = 0

    /// ⭐️ 各項目累計用量（用於顯示詳細資訊）
    private(set) var sessionSTTSeconds: Double = 0
    private(set) var sessionGPTRealtimeInputTokens: Int = 0
    private(set) var sessionGPTRealtimeOutputTokens: Int = 0
    private(set) var sessionGPTRealtimeAudioInputTokens: Int = 0
    private(set) var sessionGPTRealtimeAudioOutputTokens: Int = 0
    private(set) var sessionGPTRealtimeCallCount: Int = 0
    private(set) var sessionGPTTranscribeSeconds: Double = 0
    private(set) var sessionGPTTranscribeSegmentCount: Int = 0
    private(set) var sessionLLMInputTokens: Int = 0
    private(set) var sessionLLMOutputTokens: Int = 0
    private(set) var sessionLLMCallCount: Int = 0  // LLM 調用次數
    private(set) var sessionAgentInputTokens: Int = 0
    private(set) var sessionAgentOutputTokens: Int = 0
    private(set) var sessionAgentCallCount: Int = 0
    private(set) var sessionTTSChars: Int = 0

    /// ⭐️ 音頻加速比（1.0 = 無加速，1.5 = 1.5x 加速）
    /// 開啟加速時，STT 計費會除以此比率（節省 33%）
    private(set) var sttSpeedRatio: Double = 1.0

    // MARK: - Initialization

    private init() {
        db = Firestore.firestore(database: "realtime-voice-database")
    }

    // MARK: - Session Control

    /// 開始新的計費會話
    func startSession() {
        print("💰 [Billing] 開始計費會話")
        currentUsage = SessionUsage()
        currentSessionGPTRealtimeCreditsDeducted = 0
        isBilling = true
    }

    /// 結束計費會話，返回用量統計
    func endSession() -> SessionUsage {
        print("💰 [Billing] 結束計費會話")
        print("💰 [Billing] STT: \(String(format: "%.2f", currentUsage.sttDurationSeconds))秒, $\(String(format: "%.6f", currentUsage.sttCostUSD))")
        print("💰 [Billing] GPT Live 2: \(currentUsage.gptRealtimeInputTokens)+\(currentUsage.gptRealtimeOutputTokens) tokens, STT \(String(format: "%.2f", currentUsage.gptTranscribeDurationSeconds))秒, $\(String(format: "%.6f", currentUsage.gptRealtimeCostUSD))")
        print("💰 [Billing] LLM: \(currentUsage.llmInputTokens) input + \(currentUsage.llmOutputTokens) output tokens, $\(String(format: "%.6f", currentUsage.llmCostUSD))")
        print("💰 [Billing] Agent: \(currentUsage.agentInputTokens) input + \(currentUsage.agentOutputTokens) output tokens, $\(String(format: "%.6f", currentUsage.agentCostUSD))")
        print("💰 [Billing] TTS: \(currentUsage.ttsCharCount) chars, $\(String(format: "%.6f", currentUsage.ttsCostUSD))")
        print("💰 [Billing] 總計: $\(String(format: "%.6f", currentUsage.totalCostUSD)), 額度: \(currentUsage.totalCreditsUsed)")

        isBilling = false
        stopSTTTimer()

        return currentUsage
    }

    /// 重置當前用量
    func resetUsage() {
        currentUsage = SessionUsage()
        sttStartTime = nil
    }

    // MARK: - 音頻加速設定

    /// ⭐️ 設置音頻加速比（影響 STT 計費）
    /// - Parameter ratio: 加速比（1.0 = 無加速，1.5 = 1.5x 加速）
    /// 開啟 1.5x 加速時，STT 計費 = 實際秒數 / 1.5，節省 33%
    func setSTTSpeedRatio(_ ratio: Double) {
        sttSpeedRatio = max(1.0, ratio)  // 最小為 1.0
        if ratio > 1.0 {
            print("💰 [Billing] STT 加速模式: \(ratio)x (計費降為 \(String(format: "%.0f", 100.0 / ratio))%)")
        } else {
            print("💰 [Billing] STT 正常模式: 計費 100%")
        }
    }

    // MARK: - STT 計費（即時扣款 + PTT 模式支援）

    /// 開始 STT 計時（每秒即時扣款）
    /// ⭐️ PTT 模式：只有在 isAudioSending = true 時才計費
    /// ⭐️ 經濟模式：不調用此函數，isSTTBillingEnabled = false，跳過 STT 計費
    func startSTTTimer() {
        guard isBilling else { return }
        sttStartTime = Date()
        isSTTBillingEnabled = true  // ⭐️ 啟用 STT 計費

        // ⭐️ 只有正在發送音訊時才開始計費
        if isAudioSending {
            lastSTTBillingTime = Date()
        }

        // ⭐️ 每秒檢查一次（但只有發送時才扣款）
        sttBillingTimer?.invalidate()
        sttBillingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.processSTTBilling()
        }

        print("💰 [Billing] STT 計時開始（PTT 模式：只有發送時計費）")
    }

    /// ⭐️ 開始發送音訊（PTT 按下）- 開始計費
    func startAudioSending() {
        guard !isAudioSending else { return }
        isAudioSending = true

        // ⭐️ 只有啟用 STT 計費時才記錄時間
        if isSTTBillingEnabled {
            lastSTTBillingTime = Date()
            print("💰 [Billing] PTT 開始發送，計費啟動")
        } else {
            print("💰 [Billing] PTT 開始發送（免費 STT，不計費）")
        }
    }

    /// ⭐️ 停止發送音訊（PTT 放開）- 暫停計費
    func stopAudioSending() {
        guard isAudioSending else { return }

        // ⭐️ 只有啟用 STT 計費時才結算
        if isSTTBillingEnabled, isBilling, let lastTime = lastSTTBillingTime {
            let duration = Date().timeIntervalSince(lastTime)
            if duration > 0 {
                currentUsage.sttDurationSeconds += duration
                sessionSTTSeconds += duration

                // ⭐️ 加速模式下降低計費
                let billingDuration = duration / sttSpeedRatio
                let costUSD = billingDuration * BillingPricing.sttPricePerSecond
                let credits = Int(ceil(costUSD * BillingPricing.creditsPerUSD))
                if credits > 0 {
                    sessionSTTCreditsUsed += credits
                    let speedInfo = sttSpeedRatio > 1.0 ? " (\(sttSpeedRatio)x加速)" : ""
                    deductCreditsImmediately(credits: credits, reason: "STT(PTT結束)\(speedInfo)")
                }
            }
            print("💰 [Billing] PTT 停止發送，計費暫停")
        } else {
            print("💰 [Billing] PTT 停止發送（免費 STT，不計費）")
        }

        isAudioSending = false
        lastSTTBillingTime = nil
    }

    /// ⭐️ 處理 STT 即時扣款（每秒調用）
    /// PTT 模式：只有在發送音訊時才計費
    /// 加速模式：計費時長 = 實際時長 / 加速比
    /// 經濟模式：isSTTBillingEnabled = false，跳過計費
    private func processSTTBilling() {
        // ⭐️ 只有啟用 STT 計費且正在發送音訊時才計費
        guard isSTTBillingEnabled, isBilling, isAudioSending, let lastTime = lastSTTBillingTime else { return }

        let now = Date()
        let duration = now.timeIntervalSince(lastTime)
        lastSTTBillingTime = now

        // 累加用量（記錄實際音訊時長）
        currentUsage.sttDurationSeconds += duration
        sessionSTTSeconds += duration  // ⭐️ 累計 App 級別的 STT 秒數

        // ⭐️ 計算計費時長（加速模式下降低計費）
        // 1.5x 加速 → 計費時長 = 實際時長 / 1.5 = 實際時長 * 0.667
        let billingDuration = duration / sttSpeedRatio

        // 計算這段時間的費用並即時扣款
        let costUSD = billingDuration * BillingPricing.sttPricePerSecond
        let credits = Int(ceil(costUSD * BillingPricing.creditsPerUSD))

        if credits > 0 {
            sessionSTTCreditsUsed += credits  // ⭐️ 累計 STT 消耗額度
            let speedInfo = sttSpeedRatio > 1.0 ? " (\(sttSpeedRatio)x加速)" : ""
            deductCreditsImmediately(credits: credits, reason: "STT\(speedInfo)")
        }
    }

    /// 停止 STT 計時（結束錄音時調用）
    func stopSTTTimer() {
        // 停止計時器
        sttBillingTimer?.invalidate()
        sttBillingTimer = nil

        // ⭐️ 只有啟用 STT 計費時才結算
        if isSTTBillingEnabled, isAudioSending, let lastTime = lastSTTBillingTime {
            let duration = Date().timeIntervalSince(lastTime)
            currentUsage.sttDurationSeconds += duration
            sessionSTTSeconds += duration  // ⭐️ 累計

            // ⭐️ 加速模式下降低計費
            let billingDuration = duration / sttSpeedRatio
            let costUSD = billingDuration * BillingPricing.sttPricePerSecond
            let credits = Int(ceil(costUSD * BillingPricing.creditsPerUSD))
            if credits > 0 {
                sessionSTTCreditsUsed += credits  // ⭐️ 累計
                let speedInfo = sttSpeedRatio > 1.0 ? " (\(sttSpeedRatio)x加速)" : ""
                deductCreditsImmediately(credits: credits, reason: "STT(final)\(speedInfo)")
            }
        }

        sttStartTime = nil
        lastSTTBillingTime = nil
        isAudioSending = false

        if isSTTBillingEnabled {
            let speedInfo = sttSpeedRatio > 1.0 ? "（\(sttSpeedRatio)x加速，節省\(String(format: "%.0f", (1 - 1/sttSpeedRatio) * 100))%）" : ""
            print("💰 [Billing] STT 計時停止，累計: \(String(format: "%.2f", currentUsage.sttDurationSeconds))秒\(speedInfo)")
        } else {
            print("💰 [Billing] STT 計時停止（免費 STT，無計費）")
        }

        isSTTBillingEnabled = false  // ⭐️ 重置，下次錄音重新設定
    }

    /// 直接添加 STT 時長（秒）- 已改為即時扣款
    /// ⭐️ 經濟模式：isSTTBillingEnabled = false，跳過計費
    func addSTTDuration(seconds: Double) {
        guard isSTTBillingEnabled, isBilling else { return }
        currentUsage.sttDurationSeconds += seconds
        sessionSTTSeconds += seconds  // ⭐️ 累計

        // ⭐️ 加速模式下降低計費
        let billingSeconds = seconds / sttSpeedRatio
        let costUSD = billingSeconds * BillingPricing.sttPricePerSecond
        let credits = Int(ceil(costUSD * BillingPricing.creditsPerUSD))
        if credits > 0 {
            sessionSTTCreditsUsed += credits  // ⭐️ 累計
            let speedInfo = sttSpeedRatio > 1.0 ? " (\(sttSpeedRatio)x加速)" : ""
            deductCreditsImmediately(credits: credits, reason: "STT(add)\(speedInfo)")
        }
    }

    // MARK: - LLM 翻譯計費（即時扣款）

    /// 記錄 LLM 翻譯用量並即時扣款
    /// - Parameters:
    ///   - inputTokens: 輸入 token 數
    ///   - outputTokens: 輸出 token 數
    ///   - provider: 翻譯模型提供商（用於計算對應價格）
    func recordLLMUsage(inputTokens: Int, outputTokens: Int, provider: TranslationProvider = .gemini) {
        guard isBilling else { return }
        currentUsage.llmInputTokens += inputTokens
        currentUsage.llmOutputTokens += outputTokens

        // ⭐️ 累計 App 級別的 LLM tokens 和調用次數
        sessionLLMInputTokens += inputTokens
        sessionLLMOutputTokens += outputTokens
        sessionLLMCallCount += 1  // 每次調用 +1

        // ⭐️ 即時扣款（根據 provider 使用對應價格）
        let inputPricePerToken = provider.inputPricePerMillion / 1_000_000.0
        let outputPricePerToken = provider.outputPricePerMillion / 1_000_000.0
        let inputCost = Double(inputTokens) * inputPricePerToken
        let outputCost = Double(outputTokens) * outputPricePerToken
        let totalCostUSD = inputCost + outputCost
        let credits = Int(ceil(totalCostUSD * BillingPricing.creditsPerUSD))

        if credits > 0 {
            sessionLLMCreditsUsed += credits  // ⭐️ 累計 LLM 消耗額度
            deductCreditsImmediately(credits: credits, reason: "LLM[\(provider.rawValue)](\(inputTokens)+\(outputTokens))")
        }

        print("💰 [Billing] LLM[\(provider.rawValue)] #\(sessionLLMCallCount): +\(inputTokens) input, +\(outputTokens) output, 扣\(credits)額度 (累計: \(currentUsage.llmInputTokens)/\(currentUsage.llmOutputTokens))")
    }

    /// Records backend-priced GPT Live 2 usage. The backend applies the exact
    /// OpenAI text/audio/cached token rates and GPT Transcribe per-minute rate.
    func recordGPTRealtimeUsage(_ usage: GPTRealtime2Usage) {
        guard isBilling else { return }
        guard usage.costUSD > 0 || usage.inputTokens > 0 || usage.outputTokens > 0 else { return }

        currentUsage.gptRealtimeInputTokens += usage.inputTokens
        currentUsage.gptRealtimeOutputTokens += usage.outputTokens
        currentUsage.gptRealtimeTextInputTokens += usage.textInputTokens
        currentUsage.gptRealtimeAudioInputTokens += usage.audioInputTokens
        currentUsage.gptRealtimeCachedInputTokens += usage.cachedInputTokens
        currentUsage.gptRealtimeTextOutputTokens += usage.textOutputTokens
        currentUsage.gptRealtimeAudioOutputTokens += usage.audioOutputTokens
        currentUsage.gptTranscribeDurationSeconds += Double(usage.audioDurationMs) / 1_000
        currentUsage.gptRealtimeCostUSD += usage.costUSD

        sessionGPTRealtimeInputTokens += usage.inputTokens
        sessionGPTRealtimeOutputTokens += usage.outputTokens
        sessionGPTRealtimeAudioInputTokens += usage.audioInputTokens
        sessionGPTRealtimeAudioOutputTokens += usage.audioOutputTokens
        if usage.category == "gpt-transcribe" {
            sessionGPTTranscribeSeconds += Double(usage.audioDurationMs) / 1_000
            sessionGPTTranscribeSegmentCount += 1
        } else {
            sessionGPTRealtimeCallCount += 1
        }

        let targetCredits = Int(ceil(currentUsage.gptRealtimeCostUSD * BillingPricing.creditsPerUSD))
        let credits = max(0, targetCredits - currentSessionGPTRealtimeCreditsDeducted)
        if credits > 0 {
            currentSessionGPTRealtimeCreditsDeducted += credits
            sessionGPTRealtimeCreditsUsed += credits
            deductCreditsImmediately(
                credits: credits,
                reason: "GPT Live 2[\(usage.category)]($\(String(format: "%.6f", usage.costUSD)))"
            )
        }
    }

    /// 記錄 Dialogue Agent 用量並即時扣款
    func recordAgentUsage(
        inputTokens: Int,
        outputTokens: Int,
        model: String,
        cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        costUSD: Double? = nil
    ) {
        guard isBilling else { return }
        guard inputTokens > 0 || outputTokens > 0 else { return }

        currentUsage.agentInputTokens += inputTokens
        currentUsage.agentOutputTokens += outputTokens
        currentUsage.agentCacheReadInputTokens += cacheReadInputTokens
        currentUsage.agentCacheCreationInputTokens += cacheCreationInputTokens

        sessionAgentInputTokens += inputTokens
        sessionAgentOutputTokens += outputTokens
        sessionAgentCallCount += 1

        let calculatedCostUSD = BillingPricing.agentCostUSD(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            model: model
        )
        let totalCostUSD = max(0, costUSD ?? calculatedCostUSD)
        currentUsage.agentBilledCostUSD += totalCostUSD
        let credits = Int(ceil(totalCostUSD * BillingPricing.creditsPerUSD))

        if credits > 0 {
            sessionAgentCreditsUsed += credits
            deductCreditsImmediately(credits: credits, reason: "Agent[\(model)](\(inputTokens)+\(outputTokens))")
        }

        print("💰 [Billing] Agent[\(model)] #\(sessionAgentCallCount): +\(inputTokens) input, +\(outputTokens) output, cache=\(cacheReadInputTokens)/\(cacheCreationInputTokens), $\(String(format: "%.6f", totalCostUSD)), 扣\(credits)額度 (累計: \(currentUsage.agentInputTokens)/\(currentUsage.agentOutputTokens))")
    }

    /// 估算文本的 token 數（簡易估算：中文約 1.5 字/token，英文約 4 字符/token）
    static func estimateTokenCount(text: String) -> Int {
        // 計算中文字符數
        let chineseCount = text.filter { $0.isChineseCharacter }.count
        // 計算非中文字符數
        let otherCount = text.count - chineseCount

        // 中文約 1.5 字/token，英文約 4 字符/token
        let chineseTokens = Double(chineseCount) / 1.5
        let otherTokens = Double(otherCount) / 4.0

        return max(1, Int(ceil(chineseTokens + otherTokens)))
    }

    // MARK: - TTS 計費（即時扣款）

    /// 記錄 TTS 用量並即時扣款（按字符數計算，與 Azure TTS 計費一致）
    /// - Parameter text: 合成的文本
    func recordTTSUsage(text: String) {
        guard isBilling else { return }
        let charCount = text.count
        currentUsage.ttsCharCount += charCount
        sessionTTSChars += charCount  // ⭐️ 累計 App 級別的 TTS 字符數

        // ⭐️ 即時扣款
        let costUSD = Double(charCount) * BillingPricing.ttsPricePerChar
        let credits = Int(ceil(costUSD * BillingPricing.creditsPerUSD))

        if credits > 0 {
            sessionTTSCreditsUsed += credits  // ⭐️ 累計 TTS 消耗額度
            deductCreditsImmediately(credits: credits, reason: "TTS(\(charCount)字)")
        }

        print("💰 [Billing] TTS: +\(charCount) chars, 扣\(credits)額度 (累計: \(currentUsage.ttsCharCount))")
    }

    // MARK: - 額度檢查與扣款

    /// 檢查用戶是否有足夠額度
    /// - Parameter requiredCredits: 需要的額度數
    /// - Returns: 是否有足夠額度
    func hasEnoughCredits(requiredCredits: Int = 100) -> Bool {
        guard let user = AuthService.shared.currentUser else {
            return false
        }
        return user.slowCredits >= requiredCredits
    }

    /// ⭐️ 即時扣款（非阻塞，背景執行）
    /// - Parameters:
    ///   - credits: 要扣除的額度數
    ///   - reason: 扣款原因（用於日誌）
    private func deductCreditsImmediately(credits: Int, reason: String) {
        guard credits > 0 else { return }

        // ⭐️ 累加本次 App 使用的總消耗額度
        sessionTotalCreditsUsed += credits

        // 先更新本地額度（樂觀更新）
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            if var user = AuthService.shared.currentUser {
                let newCredits = max(0, user.slowCredits - credits)
                user.slowCredits = newCredits
                AuthService.shared.updateLocalUser(user)

                // ⭐️ 檢查額度是否耗盡
                if newCredits <= 0 {
                    print("🚨 [Billing] 額度耗盡！觸發自動停止錄音")
                    self.onCreditsExhausted?()
                }
            }
        }

        // 背景更新 Firebase
        Task {
            do {
                try await AuthService.shared.deductCredits(credits)
                print("💰 [即時扣款] \(reason): \(credits) 額度 (本次累計: \(sessionTotalCreditsUsed))")
            } catch {
                print("⚠️ [即時扣款] \(reason) 失敗: \(error.localizedDescription)")
                // 失敗時不回滾本地額度，下次同步時會自動校正
            }
        }
    }

    /// 從用戶帳戶扣除額度
    /// - Parameters:
    ///   - credits: 要扣除的額度數
    ///   - userId: 用戶 ID
    func deductCredits(credits: Int, userId: String) async throws {
        guard credits > 0 else { return }

        let userRef = db.collection("users").document(userId)

        // 使用事務確保原子性操作
        try await db.runTransaction { transaction, errorPointer in
            let userDoc: DocumentSnapshot
            do {
                userDoc = try transaction.getDocument(userRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }

            guard let currentCredits = userDoc.data()?["slow_credits"] as? Int else {
                let error = NSError(domain: "BillingService", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "無法讀取用戶額度"])
                errorPointer?.pointee = error
                return nil
            }

            let newCredits = max(0, currentCredits - credits)
            transaction.updateData(["slow_credits": newCredits, "updatedAt": FieldValue.serverTimestamp()], forDocument: userRef)

            return nil
        }

        print("💰 [Billing] 已扣除 \(credits) 額度，用戶: \(userId)")

        // 更新本地用戶資料
        await MainActor.run {
            if var user = AuthService.shared.currentUser {
                user.slowCredits = max(0, user.slowCredits - credits)
                // 注意：這裡需要 AuthService 提供更新方法
            }
        }
    }

    /// 更新用戶統計資料
    func updateUserStats(userId: String, usage: SessionUsage) async throws {
        let userRef = db.collection("users").document(userId)

        try await userRef.updateData([
            "stats.totalTokensUsed": FieldValue.increment(Int64(usage.totalTokenCount)),
            "stats.totalCost": FieldValue.increment(usage.totalCostUSD),
            "updatedAt": FieldValue.serverTimestamp()
        ])

        print("💰 [Billing] 已更新用戶統計: \(userId)")
    }

    // MARK: - 即時費用計算

    /// 獲取當前會話的即時費用（USD）
    var currentCostUSD: Double {
        var cost = currentUsage.totalCostUSD

        // 如果 STT 正在計時，加上進行中的時間
        if let startTime = sttStartTime {
            let ongoingSeconds = Date().timeIntervalSince(startTime)
            cost += ongoingSeconds * BillingPricing.sttPricePerSecond
        }

        return cost
    }

    /// 獲取當前會話的即時額度消耗
    var currentCreditsUsed: Int {
        return Int(ceil(currentCostUSD * BillingPricing.creditsPerUSD))
    }
}

// MARK: - Character Extension

extension Character {
    /// 判斷是否為中文字符
    var isChineseCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        // CJK Unified Ideographs: U+4E00 - U+9FFF
        // CJK Unified Ideographs Extension A: U+3400 - U+4DBF
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value)
    }
}
