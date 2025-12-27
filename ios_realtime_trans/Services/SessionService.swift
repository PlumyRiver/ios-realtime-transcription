//
//  SessionService.swift
//  ios_realtime_trans
//
//  Session 管理服務 - 對話記錄儲存到 Firestore
//  與 web app 共用相同的資料結構
//

import Foundation
import FirebaseFirestore

// MARK: - Conversation Item Model

/// 對話項目（儲存到 Firestore）
struct ConversationItem: Codable {
    let original: String        // 原文
    let translated: String      // 翻譯
    let timestamp: String       // ISO 時間戳
    let position: String        // "left" (對方/AI) 或 "right" (用戶)

    /// 從 TranscriptMessage 轉換
    init(from transcript: TranscriptMessage, isSource: Bool) {
        self.original = transcript.text
        self.translated = transcript.translation ?? ""
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        // isSource = true 表示用戶說的來源語言，顯示在右側
        self.position = isSource ? "right" : "left"
    }

    /// 轉換為 Firestore 字典
    func toDict() -> [String: Any] {
        return [
            "original": original,
            "translated": translated,
            "timestamp": timestamp,
            "position": position
        ]
    }
}

// MARK: - Session Service

@Observable
final class SessionService {

    // MARK: - Singleton

    static let shared = SessionService()

    // MARK: - Properties

    private let db: Firestore

    /// 當前 session ID
    private(set) var currentSessionId: String?

    /// 待保存的對話（累積後批量保存）
    private var pendingConversations: [ConversationItem] = []

    /// 保存計時器
    private var saveTimer: Timer?

    /// 保存延遲（秒）
    private let saveDelay: TimeInterval = 3.0

    /// Session 開始時間
    private var sessionStartTime: Date?

    // MARK: - Initialization

    private init() {
        // 使用與 AuthService 相同的 named database
        db = Firestore.firestore(database: "realtime-voice-database")
    }

    // MARK: - Session Management

    /// 創建新 Session
    /// - Parameters:
    ///   - uid: 用戶 ID
    ///   - sourceLang: 來源語言
    ///   - targetLang: 目標語言
    ///   - provider: STT 提供者 (chirp3, elevenlabs)
    /// - Returns: Session ID
    @MainActor
    func createSession(
        uid: String,
        sourceLang: String,
        targetLang: String,
        provider: String = "elevenlabs"
    ) async throws -> String {
        // 生成 Session ID: YYYYMMDD_HHMMSS_xxx
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: now)
        let randomSuffix = String((0..<3).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let sessionId = "\(timestamp)_\(randomSuffix)"

        // Session 資料
        let sessionData: [String: Any] = [
            "sessionId": sessionId,
            "userId": uid,
            "startTime": FieldValue.serverTimestamp(),
            "startTimeLocal": ISO8601DateFormatter().string(from: now),
            "mode": "value",  // iOS app 使用超值模式
            "model": "elevenlabs-scribe",
            "provider": provider,
            "status": "continuous",
            "isMasterSession": true,
            "sourceLang": sourceLang,
            "targetLang": targetLang,
            "tokensUsed": 0,
            "totalCost": 0.0,
            "conversationCount": 0,
            "conversations": []
        ]

        // 寫入 Firestore
        let sessionRef = db.collection("users").document(uid).collection("sessions").document(sessionId)
        try await sessionRef.setData(sessionData)

        // 更新狀態
        currentSessionId = sessionId
        sessionStartTime = now
        pendingConversations = []

        print("✅ [Session] 創建新 Session: \(sessionId)")
        return sessionId
    }

    /// 添加對話到待保存隊列
    /// - Parameters:
    ///   - transcript: 轉錄訊息
    ///   - isSource: 是否為來源語言（用戶說的）
    func addConversation(_ transcript: TranscriptMessage, isSource: Bool) {
        let item = ConversationItem(from: transcript, isSource: isSource)
        pendingConversations.append(item)

        print("📝 [Session] 添加對話: \(item.original.prefix(30))... (pending: \(pendingConversations.count))")

        // 重置保存計時器（延遲批量保存）
        scheduleDelayedSave()
    }

    /// 安排延遲保存
    private func scheduleDelayedSave() {
        // 取消之前的計時器
        saveTimer?.invalidate()

        // 3 秒後保存
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.saveConversations()
            }
        }
    }

    /// 保存對話到 Firestore
    @MainActor
    func saveConversations() async {
        guard let sessionId = currentSessionId,
              let uid = AuthService.shared.currentUser?.uid,
              !pendingConversations.isEmpty else {
            return
        }

        let conversationsToSave = pendingConversations
        pendingConversations = []  // 清空待保存隊列

        do {
            let sessionRef = db.collection("users").document(uid).collection("sessions").document(sessionId)

            // 獲取現有對話
            let document = try await sessionRef.getDocument()
            var existingConversations: [[String: Any]] = []

            if let data = document.data(),
               let conversations = data["conversations"] as? [[String: Any]] {
                existingConversations = conversations
            }

            // 合併新對話
            let newConversations = conversationsToSave.map { $0.toDict() }
            existingConversations.append(contentsOf: newConversations)

            // 更新 Firestore
            try await sessionRef.updateData([
                "conversations": existingConversations,
                "conversationCount": existingConversations.count,
                "updatedAt": FieldValue.serverTimestamp()
            ])

            print("✅ [Session] 保存 \(conversationsToSave.count) 條對話，總計: \(existingConversations.count)")

        } catch {
            print("❌ [Session] 保存對話失敗: \(error.localizedDescription)")
            // 失敗時恢復待保存隊列
            pendingConversations = conversationsToSave + pendingConversations
        }
    }

    /// 立即保存所有待處理對話（用於結束錄音時）
    @MainActor
    func flushConversations() async {
        saveTimer?.invalidate()
        saveTimer = nil
        await saveConversations()
    }

    /// 更新 Session 狀態
    @MainActor
    func updateSession(status: String = "paused", duration: TimeInterval? = nil) async {
        guard let sessionId = currentSessionId,
              let uid = AuthService.shared.currentUser?.uid else {
            return
        }

        var updateData: [String: Any] = [
            "status": status,
            "updatedAt": FieldValue.serverTimestamp(),
            "lastActivity": FieldValue.serverTimestamp()
        ]

        if let duration = duration {
            updateData["lastDuration"] = Int(duration * 1000)  // 轉換為毫秒
        }

        do {
            let sessionRef = db.collection("users").document(uid).collection("sessions").document(sessionId)
            try await sessionRef.updateData(updateData)
            print("✅ [Session] 更新狀態: \(status)")
        } catch {
            print("❌ [Session] 更新狀態失敗: \(error.localizedDescription)")
        }
    }

    /// 結束 Session
    /// - Returns: 本次會話的用量統計（用於扣款）
    @MainActor
    func endSession() async -> SessionUsage? {
        // 先保存所有待處理對話
        await flushConversations()

        guard let sessionId = currentSessionId,
              let uid = AuthService.shared.currentUser?.uid else {
            return nil
        }

        // 計算持續時間
        let duration: TimeInterval
        if let startTime = sessionStartTime {
            duration = Date().timeIntervalSince(startTime)
        } else {
            duration = 0
        }

        // ⭐️ 獲取計費數據
        let usage = BillingService.shared.endSession()

        do {
            let sessionRef = db.collection("users").document(uid).collection("sessions").document(sessionId)
            try await sessionRef.updateData([
                "status": "ended",
                "endTime": FieldValue.serverTimestamp(),
                "lastDuration": Int(duration * 1000),
                "updatedAt": FieldValue.serverTimestamp(),
                // ⭐️ 保存計費數據
                "billing": usage.toFirestoreData(),
                "tokensUsed": usage.llmInputTokens + usage.llmOutputTokens,
                "totalCost": usage.totalCostUSD
            ])

            print("✅ [Session] 結束 Session: \(sessionId), 持續: \(Int(duration))秒")
            print("💰 [Session] 計費: STT \(String(format: "%.2f", usage.sttDurationSeconds))秒, LLM \(usage.llmInputTokens + usage.llmOutputTokens) tokens, TTS \(usage.ttsCharCount) chars")
            print("💰 [Session] 總費用: $\(String(format: "%.6f", usage.totalCostUSD)), 額度: \(usage.totalCreditsUsed)")

            // 更新用戶統計
            await updateUserStats(usage: usage)

        } catch {
            print("❌ [Session] 結束 Session 失敗: \(error.localizedDescription)")
        }

        // 清理狀態
        currentSessionId = nil
        sessionStartTime = nil
        pendingConversations = []

        return usage
    }

    /// 更新用戶統計
    /// - Parameter usage: 本次會話的用量統計
    private func updateUserStats(usage: SessionUsage) async {
        guard let uid = AuthService.shared.currentUser?.uid else { return }

        do {
            let userRef = db.collection("users").document(uid)

            // ⭐️ 使用 Firestore increment 確保原子性更新
            try await userRef.updateData([
                "stats.totalSessions": FieldValue.increment(Int64(1)),
                "stats.totalTokensUsed": FieldValue.increment(Int64(usage.llmInputTokens + usage.llmOutputTokens)),
                "stats.totalCost": FieldValue.increment(usage.totalCostUSD),
                "updatedAt": FieldValue.serverTimestamp()
            ])

            print("✅ [Session] 更新用戶統計: +1 session, +\(usage.llmInputTokens + usage.llmOutputTokens) tokens, +$\(String(format: "%.6f", usage.totalCostUSD))")
        } catch {
            print("⚠️ [Session] 更新用戶統計失敗: \(error.localizedDescription)")
        }
    }

    /// 檢查是否有活躍 Session
    var hasActiveSession: Bool {
        return currentSessionId != nil
    }
}
