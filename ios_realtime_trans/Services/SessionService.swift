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

    /// ⭐️ 收藏快取：dateKey("yyyy/MM/dd") → 名稱
    private(set) var favoritesCache: [String: String] = [:]
    private var favoritesCacheUid: String?
    private var favoritesCacheLoaded = false

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

    // MARK: - Session History（過往對話紀錄）

    /// 是否已確認 documentID 索引可用
    private var useDocumentIdOrder: Bool?

    /// ⭐️ 記憶體快取：避免每次開歷史都重新讀全部
    private var cachedSessions: [SessionSummary] = []
    private var cacheUid: String?
    private var cacheFullyLoaded: Bool = false

    /// 取得全部歷史（快取優先 + 差量同步）
    ///
    /// 策略：
    /// 1. 如果記憶體快取有資料且 uid 一致 → 立刻回傳快取（0 次 Firestore 讀取）
    /// 2. 同時在背景抓「比快取中最新 session 更新的」文件（差量同步）
    /// 3. 第一次開（快取空）→ 從 Firestore 全量載入
    ///
    /// - Parameters:
    ///   - uid: 用戶 ID
    ///   - onBatchLoaded: 每載入一批就回調（用於 UI 即時更新）
    func loadAllSessions(
        uid: String,
        onBatchLoaded: @escaping ([SessionSummary], _ isComplete: Bool) -> Void
    ) async {
        // ⭐️ 1) 記憶體快取命中
        if cacheUid == uid && !cachedSessions.isEmpty {
            print("⚡️ [Session] 記憶體快取命中: \(cachedSessions.count) 筆（0 次 Firestore 讀取）")
            onBatchLoaded(cachedSessions, cacheFullyLoaded)
            await deltaSync(uid: uid, onBatchLoaded: onBatchLoaded)
            return
        }

        // ⭐️ 2) 磁碟快取命中
        if let diskSessions = loadFromDisk(uid: uid) {
            cachedSessions = diskSessions
            cacheUid = uid
            cacheFullyLoaded = true  // 磁碟快取是上次全量載入的完整結果
            onBatchLoaded(cachedSessions, true)
            await deltaSync(uid: uid, onBatchLoaded: onBatchLoaded)
            return
        }

        // ⭐️ 3) 完全未命中：全量載入
        print("📥 [Session] 無快取，全量載入...")
        cacheUid = uid
        cachedSessions = []
        cacheFullyLoaded = false

        var lastDocument: DocumentSnapshot?
        var hasMore = true
        let pageSize = 100
        var retryCount = 0

        while hasMore {
            do {
                let result = try await fetchSessions(uid: uid, limit: pageSize, lastDocument: lastDocument)
                cachedSessions.append(contentsOf: result.sessions)
                lastDocument = result.lastDocument
                hasMore = result.lastDocument != nil
                retryCount = 0

                // 每批回調 UI
                onBatchLoaded(cachedSessions, !hasMore)
            } catch {
                retryCount += 1
                print("❌ [Session] 載入失敗 (第 \(retryCount) 次, 已載入 \(cachedSessions.count) 筆): \(error.localizedDescription)")
                if retryCount >= 3 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        cacheFullyLoaded = !hasMore
        // ⭐️ 全量載入完成後存到磁碟
        saveToDisk(uid: uid)
        print("✅ [Session] 全量載入完成: \(cachedSessions.count) 筆，Firestore 讀取 \(cachedSessions.count) 次")
    }

    /// 差量同步：只抓比快取最新 session 更新的文件
    private func deltaSync(
        uid: String,
        onBatchLoaded: @escaping ([SessionSummary], Bool) -> Void
    ) async {
        guard let newestId = cachedSessions.first?.id else { return }
        do {
            let newSessions = try await fetchSessionsNewerThan(uid: uid, sessionId: newestId)
            if !newSessions.isEmpty {
                cachedSessions.insert(contentsOf: newSessions, at: 0)
                saveToDisk(uid: uid)
                print("🔄 [Session] 差量同步: +\(newSessions.count) 筆新 session")
                onBatchLoaded(cachedSessions, cacheFullyLoaded)
            }
        } catch {
            print("⚠️ [Session] 差量同步失敗: \(error.localizedDescription)")
        }
    }

    /// 當 endSession 被呼叫後，讓下次開歷史時能看到新 session
    func invalidateHistoryCache() {
        cacheFullyLoaded = false
    }

    // MARK: - Disk Cache（持久化快取，app 重啟也不用重新讀取全部）

    /// 磁碟快取檔案路徑（Application Support — 永久保存，不會被系統清除）
    private func diskCachePath(uid: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Application Support 目錄可能不存在，確保建立
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session_history_\(uid).json")
    }

    /// 儲存到磁碟（只存 metadata，不存對話內容）
    private func saveToDisk(uid: String) {
        let entries = cachedSessions.map { CachedSession(from: $0) }
        let wrapper = CachedSessionFile(uid: uid, sessions: entries)
        do {
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: diskCachePath(uid: uid), options: .atomic)
            print("💾 [Session] 磁碟快取已儲存: \(entries.count) 筆 (\(data.count / 1024) KB)")
        } catch {
            print("⚠️ [Session] 磁碟快取儲存失敗: \(error.localizedDescription)")
        }
    }

    /// 從磁碟讀取快取
    private func loadFromDisk(uid: String) -> [SessionSummary]? {
        let path = diskCachePath(uid: uid)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            let data = try Data(contentsOf: path)
            let wrapper = try JSONDecoder().decode(CachedSessionFile.self, from: data)
            guard wrapper.uid == uid else { return nil }
            let sessions = wrapper.sessions.map { SessionSummary(fromCache: $0) }
            print("⚡️ [Session] 磁碟快取載入: \(sessions.count) 筆 (\(data.count / 1024) KB)")
            return sessions
        } catch {
            print("⚠️ [Session] 磁碟快取讀取失敗: \(error.localizedDescription)")
            return nil
        }
    }

    /// 按需抓取單個 session 的對話內容（展開日期時呼叫）
    func fetchConversations(uid: String, sessionId: String) async throws -> [ConversationItem] {
        let docRef = db.collection("users").document(uid).collection("sessions").document(sessionId)
        let doc = try await docRef.getDocument()
        guard let data = doc.data(),
              let convArray = data["conversations"] as? [[String: Any]] else {
            return []
        }
        return convArray.map { dict in
            ConversationItem(
                original: dict["original"] as? String ?? "",
                translated: dict["translated"] as? String ?? "",
                timestamp: dict["timestamp"] as? String ?? "",
                position: dict["position"] as? String ?? "right"
            )
        }
    }

    // MARK: - Private Fetch Methods

    /// 抓比指定 sessionId 更新的 session（用於差量同步）
    private func fetchSessionsNewerThan(uid: String, sessionId: String) async throws -> [SessionSummary] {
        let collectionRef = db.collection("users").document(uid).collection("sessions")
        await ensureOrderStrategy(collectionRef: collectionRef)

        var query: Query
        if useDocumentIdOrder == true {
            query = collectionRef
                .order(by: FieldPath.documentID(), descending: true)
                .end(before: [sessionId])
        } else {
            // startTime 排序下無法精確用 ID 做差量，改用時間
            query = collectionRef
                .order(by: "startTime", descending: true)
                .limit(to: 50)
        }

        let snapshot = try await query.getDocuments()
        let newSessions = snapshot.documents.compactMap { SessionSummary(document: $0) }

        if useDocumentIdOrder != true {
            // 用 startTime 排序時需要手動去重
            let existingIds = Set(cachedSessions.prefix(50).map { $0.id })
            return newSessions.filter { !existingIds.contains($0.id) }
        }

        print("📋 [Session] 差量查詢: \(newSessions.count) 筆新 session")
        return newSessions
    }

    /// 確保已偵測排序策略
    private func ensureOrderStrategy(collectionRef: CollectionReference) async {
        guard useDocumentIdOrder == nil else { return }
        do {
            let testQuery = collectionRef
                .order(by: FieldPath.documentID(), descending: true)
                .limit(to: 1)
            _ = try await testQuery.getDocuments()
            useDocumentIdOrder = true
            print("✅ [Session] documentID 索引可用")
        } catch {
            useDocumentIdOrder = false
            print("⚠️ [Session] documentID 索引不可用，退回 startTime")
        }
    }

    /// 分頁抓取（內部使用）
    private func fetchSessions(
        uid: String,
        limit: Int = 100,
        lastDocument: DocumentSnapshot? = nil
    ) async throws -> (sessions: [SessionSummary], lastDocument: DocumentSnapshot?) {

        let collectionRef = db.collection("users").document(uid).collection("sessions")
        await ensureOrderStrategy(collectionRef: collectionRef)

        var query: Query
        if useDocumentIdOrder == true {
            query = collectionRef.order(by: FieldPath.documentID(), descending: true).limit(to: limit)
        } else {
            query = collectionRef.order(by: "startTime", descending: true).limit(to: limit)
        }

        if let lastDoc = lastDocument {
            query = query.start(afterDocument: lastDoc)
        }

        let snapshot = try await query.getDocuments()
        let sessions = snapshot.documents.compactMap { SessionSummary(document: $0) }
        let lastDoc = snapshot.documents.count < limit ? nil : snapshot.documents.last
        return (sessions, lastDoc)
    }
}

// MARK: - Session Summary Model（歷史列表用）

struct SessionSummary: Identifiable {
    let id: String              // sessionId
    let startTime: Date
    let sourceLang: String
    let targetLang: String
    let conversationCount: Int
    let durationMs: Int         // lastDuration（毫秒）
    let status: String

    // ⭐️ 對話內容延遲解析：列表只需要 metadata，展開時才呼叫 parseConversations()
    private let rawConversations: [[String: Any]]

    /// 解析對話內容（僅在展開時呼叫，避免首次載入時解析成千上萬的物件）
    func parseConversations() -> [ConversationItem] {
        rawConversations.map { dict in
            ConversationItem(
                original: dict["original"] as? String ?? "",
                translated: dict["translated"] as? String ?? "",
                timestamp: dict["timestamp"] as? String ?? "",
                position: dict["position"] as? String ?? "right"
            )
        }
    }

    // ⭐️ 靜態 DateFormatter 快取（避免每個 session 都重新配置）
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; return f
    }()
    private static let docIdFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f
    }()
    private static let isoFormatter = ISO8601DateFormatter()

    /// 從 Firestore document 解析（只解析 metadata，不解析 conversations）
    init?(document: DocumentSnapshot) {
        guard let data = document.data() else { return nil }

        self.id = data["sessionId"] as? String ?? document.documentID

        // startTime 多重 fallback
        if let ts = data["startTime"] as? Timestamp {
            self.startTime = ts.dateValue()
        } else if let local = data["startTimeLocal"] as? String,
                  let date = Self.isoFormatter.date(from: local) {
            self.startTime = date
        } else {
            let dateStr = String(document.documentID.prefix(15))
            self.startTime = Self.docIdFormatter.date(from: dateStr) ?? Date()
        }

        self.sourceLang = data["sourceLang"] as? String ?? "?"
        self.targetLang = data["targetLang"] as? String ?? "?"
        self.conversationCount = data["conversationCount"] as? Int ?? 0
        self.durationMs = data["lastDuration"] as? Int ?? 0
        self.status = data["status"] as? String ?? "unknown"

        // ⭐️ 只存原始字典，不解析 — 展開時才呼叫 parseConversations()
        self.rawConversations = data["conversations"] as? [[String: Any]] ?? []
    }

    var formattedDuration: String {
        let seconds = durationMs / 1000
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return secs > 0 ? "\(minutes)分\(secs)秒" : "\(minutes)分鐘"
    }

    var formattedTime: String { Self.timeFormatter.string(from: startTime) }

    var formattedDate: String { Self.dateFormatter.string(from: startTime) }

    var languagePair: String {
        let src = Language(rawValue: sourceLang)?.shortName ?? sourceLang
        let tgt = Language(rawValue: targetLang)?.shortName ?? targetLang
        return "\(src) → \(tgt)"
    }

    var sessionDividerText: String {
        var parts: [String] = []
        if durationMs > 0 { parts.append(formattedDuration) }
        parts.append("\(conversationCount)則訊息")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Disk Cache Models

/// 磁碟快取用的輕量 session（只有 metadata，不含對話內容）
struct CachedSession: Codable {
    let id: String
    let startTime: Date
    let sourceLang: String
    let targetLang: String
    let conversationCount: Int
    let durationMs: Int
    let status: String

    init(from summary: SessionSummary) {
        self.id = summary.id
        self.startTime = summary.startTime
        self.sourceLang = summary.sourceLang
        self.targetLang = summary.targetLang
        self.conversationCount = summary.conversationCount
        self.durationMs = summary.durationMs
        self.status = summary.status
    }
}

/// 磁碟快取檔案結構
struct CachedSessionFile: Codable {
    let uid: String
    let sessions: [CachedSession]
}

// MARK: - SessionSummary 從快取初始化

extension SessionSummary {
    /// 從磁碟快取初始化（沒有對話內容，展開時按需從 Firestore 抓）
    init(fromCache cached: CachedSession) {
        self.id = cached.id
        self.startTime = cached.startTime
        self.sourceLang = cached.sourceLang
        self.targetLang = cached.targetLang
        self.conversationCount = cached.conversationCount
        self.durationMs = cached.durationMs
        self.status = cached.status
        self.rawConversations = []  // 空的，展開時按需載入
    }
}

// MARK: - ConversationItem 擴充初始化（從字典）

extension ConversationItem {
    init(original: String, translated: String, timestamp: String, position: String) {
        self.original = original
        self.translated = translated
        self.timestamp = timestamp
        self.position = position
    }
}

// MARK: - Favorites (收藏)

extension SessionService {

    /// ⭐️ 載入收藏（三層快取：記憶體 → 磁碟 → Firestore）
    ///
    /// 策略：
    /// 1. 記憶體快取命中 → 0 次 Firestore 讀取，背景同步
    /// 2. 磁碟快取命中 → 0 次 Firestore 讀取，背景同步
    /// 3. 都沒有 → 從 Firestore 全量載入，存磁碟
    func loadFavorites(uid: String) async {
        // 1) 記憶體快取命中
        if favoritesCacheUid == uid && favoritesCacheLoaded {
            print("⚡️ [Favorites] 記憶體快取命中: \(favoritesCache.count) 個（0 次 Firestore 讀取）")
            // 背景同步確保跨裝置更新
            Task { await syncFavoritesFromFirestore(uid: uid) }
            return
        }

        // 2) 磁碟快取命中
        if let diskData = loadFavoritesFromDisk(uid: uid) {
            favoritesCache = diskData
            favoritesCacheUid = uid
            favoritesCacheLoaded = true
            print("⚡️ [Favorites] 磁碟快取命中: \(diskData.count) 個（0 次 Firestore 讀取）")
            // 背景同步
            Task { await syncFavoritesFromFirestore(uid: uid) }
            return
        }

        // 3) 完全無快取 → Firestore 全量載入
        await syncFavoritesFromFirestore(uid: uid)
    }

    /// 從 Firestore 同步收藏（全量讀取 → 更新記憶體 + 磁碟）
    private func syncFavoritesFromFirestore(uid: String) async {
        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("favorites").getDocuments()
            var loaded: [String: String] = [:]
            for doc in snapshot.documents {
                let data = doc.data()
                if let name = data["name"] as? String {
                    let dateKey = data["dateKey"] as? String
                        ?? doc.documentID.replacingOccurrences(of: "-", with: "/")
                    loaded[dateKey] = name
                }
            }
            // 只在有差異時更新
            if loaded != favoritesCache {
                favoritesCache = loaded
                saveFavoritesToDisk(uid: uid)
                print("🔄 [Favorites] Firestore 同步: \(loaded.count) 個（已更新磁碟快取）")
            } else {
                print("⭐️ [Favorites] Firestore 同步: 無變化")
            }
            favoritesCacheUid = uid
            favoritesCacheLoaded = true
        } catch {
            print("❌ [Favorites] Firestore 同步失敗: \(error.localizedDescription)")
        }
    }

    /// ⭐️ 儲存收藏（命名 = 收藏，寫入 Firestore 跨裝置同步）
    func saveFavorite(uid: String, dateKey: String, name: String) async {
        // 先更新本地（樂觀更新）
        favoritesCache[dateKey] = name
        saveFavoritesToDisk(uid: uid)

        let docId = dateKey.replacingOccurrences(of: "/", with: "-")
        let docRef = db.collection("users").document(uid)
            .collection("favorites").document(docId)
        do {
            try await docRef.setData([
                "name": name,
                "dateKey": dateKey,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
            print("⭐️ [Favorites] 已收藏: \(dateKey) → \(name)")
        } catch {
            print("❌ [Favorites] 儲存失敗: \(error.localizedDescription)")
        }
    }

    /// ⭐️ 移除收藏
    func removeFavorite(uid: String, dateKey: String) async {
        // 先更新本地（樂觀更新）
        favoritesCache.removeValue(forKey: dateKey)
        saveFavoritesToDisk(uid: uid)

        let docId = dateKey.replacingOccurrences(of: "/", with: "-")
        let docRef = db.collection("users").document(uid)
            .collection("favorites").document(docId)
        do {
            try await docRef.delete()
            print("⭐️ [Favorites] 已移除收藏: \(dateKey)")
        } catch {
            print("❌ [Favorites] 移除失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Favorites Disk Cache

    /// 磁碟快取路徑（Application Support — 不會被系統清除）
    private func favoritesDiskPath(uid: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("favorites_\(uid).json")
    }

    /// 儲存到磁碟
    private func saveFavoritesToDisk(uid: String) {
        do {
            let wrapper = CachedFavoritesFile(uid: uid, favorites: favoritesCache)
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: favoritesDiskPath(uid: uid), options: .atomic)
            print("💾 [Favorites] 磁碟快取已儲存: \(favoritesCache.count) 個")
        } catch {
            print("⚠️ [Favorites] 磁碟快取儲存失敗: \(error.localizedDescription)")
        }
    }

    /// 從磁碟讀取
    private func loadFavoritesFromDisk(uid: String) -> [String: String]? {
        let path = favoritesDiskPath(uid: uid)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            let data = try Data(contentsOf: path)
            let wrapper = try JSONDecoder().decode(CachedFavoritesFile.self, from: data)
            guard wrapper.uid == uid else { return nil }
            print("⚡️ [Favorites] 磁碟快取讀取: \(wrapper.favorites.count) 個")
            return wrapper.favorites
        } catch {
            print("⚠️ [Favorites] 磁碟快取讀取失敗: \(error.localizedDescription)")
            return nil
        }
    }
}

/// 收藏磁碟快取結構
struct CachedFavoritesFile: Codable {
    let uid: String
    let favorites: [String: String]  // dateKey → name
}
