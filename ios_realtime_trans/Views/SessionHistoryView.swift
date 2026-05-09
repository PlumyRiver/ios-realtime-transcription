//
//  SessionHistoryView.swift
//  ios_realtime_trans
//
//  過往對話紀錄（日期選擇 → 展開當天對話）
//  ⭐️ 支援收藏：命名日期 = 收藏，存到 Firestore 跨裝置同步
//
//  ⭐️ 效能架構：
//  使用 @Observable SessionHistoryState 做細粒度觀察。
//  - SessionHistoryView 只讀 showRenameSheet 相關屬性 → rename 操作不觸發列表重算
//  - SessionHistoryContent 只讀 sessions/favorites 等列表屬性 → 列表更新不觸發 rename UI
//  - RenameSheet 自帶 @State text → 鍵盤輸入完全隔離
//

import SwiftUI

// MARK: - Shared State（@Observable 細粒度追蹤）

@Observable
class SessionHistoryState {
    let uid: String

    // ── 列表資料（由 SessionHistoryContent 讀取）──
    var sessions: [SessionSummary] = []
    var isLoading = false
    var isComplete = false
    var favorites: [String: String] = [:]

    /// ⭐️ 預算好的分組（只在 sessions 變化時重算，不在每次 body eval 重算）
    var groupedSessions: [DateGroup] = []

    /// ⭐️ 靜態 DateFormatter（跟 SessionHistoryContent 共用邏輯，但只算一次）
    private static let parseFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; return f
    }()
    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh-TW"); f.dateFormat = "EEEE"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh-TW"); f.dateFormat = "M月d日 EEEE"; return f
    }()

    private func recomputeGroups() {
        let grouped = Dictionary(grouping: sessions) { $0.formattedDate }
        groupedSessions = grouped.map { (key, value) in
            DateGroup(
                date: key,
                sessions: value,
                displayDate: Self.formatDate(key),
                totalConversations: value.reduce(0) { $0 + $1.conversationCount }
            )
        }.sorted { $0.date > $1.date }
    }

    private static func formatDate(_ dateString: String) -> String {
        guard let date = parseFmt.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return weekdayFmt.string(from: date)
        }
        return dateFmt.string(from: date)
    }

    // ── 命名 Sheet 狀態（由 SessionHistoryView 讀取）──
    var showRenameSheet = false
    var renamingDateKey = ""
    var renamingInitialText = ""
    var renamingIsEdit = false

    init(uid: String) { self.uid = uid }

    /// 開始命名/改名
    func startRename(dateKey: String, currentName: String?) {
        renamingDateKey = dateKey
        if let name = currentName {
            renamingInitialText = name
            renamingIsEdit = true
        } else {
            renamingInitialText = "\(dateKey) "
            renamingIsEdit = false
        }
        showRenameSheet = true
    }

    /// 確認收藏
    func confirmRename(name: String) {
        favorites[renamingDateKey] = name
        showRenameSheet = false
        let dateKey = renamingDateKey
        let uid = self.uid
        Task {
            await SessionService.shared.saveFavorite(uid: uid, dateKey: dateKey, name: name)
        }
    }

    /// 移除收藏
    func removeFavorite(dateKey: String) {
        favorites.removeValue(forKey: dateKey)
        showRenameSheet = false
        let uid = self.uid
        Task {
            await SessionService.shared.removeFavorite(uid: uid, dateKey: dateKey)
        }
    }

    /// 載入全部資料
    func loadData() async {
        async let h: () = loadSessions()
        async let f: () = loadFavorites()
        _ = await (h, f)
    }

    private func loadSessions() async {
        isLoading = true
        await SessionService.shared.loadAllSessions(uid: uid) { [weak self] loaded, complete in
            self?.sessions = loaded
            self?.isComplete = complete
            self?.isLoading = !complete
            if complete {
                self?.recomputeGroups()
            }
        }
        isLoading = false
        isComplete = true
        recomputeGroups()
    }

    private func loadFavorites() async {
        await SessionService.shared.loadFavorites(uid: uid)
        favorites = SessionService.shared.favoritesCache
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let latest = SessionService.shared.favoritesCache
        if latest != favorites { favorites = latest }
    }
}

// MARK: - 薄殼（只讀 rename 相關屬性）

struct SessionHistoryView: View {
    @State private var state: SessionHistoryState
    @Environment(\.dismiss) private var dismiss

    init(uid: String) {
        _state = State(initialValue: SessionHistoryState(uid: uid))
    }

    var body: some View {
        NavigationStack {
            SessionHistoryContent(state: state)
                .navigationTitle("對話紀錄")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                .task { await state.loadData() }
        }
        // ⭐️ .sheet 放在 NavigationStack 外面，與 SessionHistoryContent 完全脫鉤
        // 這樣 showRenameSheet 切換不會觸發 SessionHistoryContent.body 重算
        .sheet(isPresented: $state.showRenameSheet) {
            RenameSheet(
                initialText: state.renamingInitialText,
                isEdit: state.renamingIsEdit,
                onConfirm: { name in state.confirmRename(name: name) },
                onRemove: state.renamingIsEdit ? {
                    state.removeFavorite(dateKey: state.renamingDateKey)
                } : nil,
                onCancel: { state.showRenameSheet = false }
            )
            .presentationDetents([.medium])
        }
    }
}

// MARK: - 列表內容（只讀 sessions/favorites，不讀 rename 狀態）

private struct SessionHistoryContent: View {
    var state: SessionHistoryState
    @State private var expandedDate: String?
    @State private var conversationCache: [String: [ConversationItem]] = [:]
    @State private var loadingConversationIds: Set<String> = []
    @State private var failedConversationIds: Set<String> = []
    @State private var showFavoritesOnly = false
    private static let conversationTimestampFormatter = ISO8601DateFormatter()

    var body: some View {
        // ⭐️ 計算一次，避免 filteredGroups 在 body 裡多次重算
        let groups = currentGroups
        VStack(spacing: 0) {
            tabSelector

            if groups.isEmpty && !state.isLoading {
                if showFavoritesOnly {
                    favoritesEmptyState
                } else {
                    emptyState
                }
            } else {
                dateListView(groups: groups)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var currentGroups: [DateGroup] {
        if showFavoritesOnly {
            return state.groupedSessions.filter { favoriteName(for: $0.date) != nil }
        }
        return state.groupedSessions
    }

    private func favoriteName(for date: String) -> String? {
        state.favorites[date] ?? state.favorites[date.replacingOccurrences(of: "/", with: "-")]
    }

    // MARK: - Tab

    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabButton(title: "全部", isActive: !showFavoritesOnly) {
                withAnimation(.easeInOut(duration: 0.2)) { showFavoritesOnly = false }
            }
            tabButton(title: "收藏", count: state.favorites.count, isActive: showFavoritesOnly) {
                withAnimation(.easeInOut(duration: 0.2)) { showFavoritesOnly = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func tabButton(title: String, count: Int? = nil, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isActive ? .bold : .regular)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isActive ? Color.orange : Color(.systemGray4))
                        .foregroundStyle(.white)
                        .cornerRadius(8)
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(isActive ? Color.blue : Color.clear)
                        .frame(height: 2)
                }
            )
        }
    }

    // MARK: - Date List

    private func dateListView(groups: [DateGroup]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if state.isLoading && !showFavoritesOnly {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("載入中… \(state.sessions.count) 筆")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }

                ForEach(groups) { group in
                    let favName = favoriteName(for: group.date)
                    let isFav = favName != nil

                    DateChipView(
                        dateString: group.date,
                        displayDate: group.displayDate,
                        sessionCount: group.sessions.count,
                        messageCount: group.totalConversations,
                        isExpanded: expandedDate == group.date,
                        isFavorited: isFav,
                        favoriteName: favName,
                        onStarTapped: {
                            state.startRename(dateKey: group.date, currentName: favName)
                        },
                        onStarLongPressed: {
                            if isFav { state.removeFavorite(dateKey: group.date) }
                        },
                        onExpandTapped: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                expandedDate = expandedDate == group.date ? nil : group.date
                            }
                        }
                    )

                    if expandedDate == group.date {
                        expandedContent(for: group).transition(.opacity)
                    }
                }

                if !showFavoritesOnly && state.isComplete && !state.sessions.isEmpty {
                    Text("共 \(state.sessions.count) 筆 · \(groups.count) 天")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Expanded Content

    private func expandedContent(for group: DateGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sessionsOldestFirst(group.sessions).enumerated()), id: \.element.id) { _, session in
                SessionDividerView(
                    text: session.sessionDividerText,
                    languagePair: session.languagePair,
                    time: session.formattedTime
                )
                conversationContent(for: session)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private func conversationContent(for session: SessionSummary) -> some View {
        if let cached = conversationCache[session.id] {
            if cached.isEmpty {
                emptyConversationText(session.conversationCount > 0 ? "（找不到對話內容）" : "（無對話內容）")
            } else {
                conversationList(cached)
            }
        } else {
            let parsed = session.parseConversations()
            if !parsed.isEmpty {
                conversationList(parsed)
            } else if session.conversationCount > 0 {
                if failedConversationIds.contains(session.id) {
                    emptyConversationText("（載入對話內容失敗）")
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("載入對話內容…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .task(id: session.id) {
                        await loadConversationsIfNeeded(for: session)
                    }
                }
            } else {
                emptyConversationText("（無對話內容）")
            }
        }
    }

    private func conversationList(_ conversations: [ConversationItem]) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(conversationsOldestFirst(conversations).enumerated()), id: \.offset) { _, conv in
                ConversationBubble(conversation: conv)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func sessionsOldestFirst(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime { return lhs.id < rhs.id }
            return lhs.startTime < rhs.startTime
        }
    }

    private func conversationsOldestFirst(_ conversations: [ConversationItem]) -> [ConversationItem] {
        conversations.enumerated().sorted { lhs, rhs in
            let lhsDate = conversationDate(lhs.element.timestamp)
            let rhsDate = conversationDate(rhs.element.timestamp)

            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate == rhsDate { return lhs.offset < rhs.offset }
                return lhsDate < rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func conversationDate(_ timestamp: String) -> Date? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self.conversationTimestampFormatter.date(from: trimmed)
    }

    private func emptyConversationText(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.vertical, 8)
    }

    @MainActor
    private func loadConversationsIfNeeded(for session: SessionSummary) async {
        guard conversationCache[session.id] == nil,
              !loadingConversationIds.contains(session.id) else {
            return
        }

        let parsed = session.parseConversations()
        if !parsed.isEmpty {
            conversationCache[session.id] = parsed
            return
        }

        loadingConversationIds.insert(session.id)
        failedConversationIds.remove(session.id)

        do {
            let convs = try await SessionService.shared.fetchConversations(
                uid: state.uid,
                sessionId: session.id
            )
            conversationCache[session.id] = convs
        } catch {
            failedConversationIds.insert(session.id)
        }

        loadingConversationIds.remove(session.id)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("尚無對話紀錄").font(.headline).foregroundStyle(.secondary)
            Text("開始錄音對話後，紀錄會自動保存到這裡")
                .font(.subheadline).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var favoritesEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star")
                .font(.system(size: 48)).foregroundStyle(.orange.opacity(0.5))
            Text("尚無收藏紀錄").font(.headline).foregroundStyle(.secondary)
            Text("點擊星號，為對話命名即可收藏")
                .font(.subheadline).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
    }


}

// MARK: - Rename Sheet（自帶 @State，鍵盤輸入完全隔離）

private struct RenameSheet: View {
    let initialText: String
    let isEdit: Bool
    var onConfirm: (String) -> Void
    var onRemove: (() -> Void)?
    var onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { onCancel() }.foregroundStyle(.blue)
                Spacer()
                Text(isEdit ? "編輯名稱" : "為對話命名").font(.headline)
                Spacer()
                Button("收藏") {
                    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { onConfirm(name) }
                }
                .bold()
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal).padding(.top, 20).padding(.bottom, 12)

            TextField("輸入名稱", text: $text)
                .textFieldStyle(.plain).font(.body)
                .padding(12)
                .background(Color(.systemGray6)).cornerRadius(12)
                .focused($isFocused)
                .padding(.horizontal)

            if isEdit, let onRemove {
                Button("移除收藏", role: .destructive) { onRemove() }
                    .font(.subheadline).padding(.top, 12)
            }

            Spacer()
        }
        .onAppear {
            text = initialText
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isFocused = true }
        }
    }
}

// MARK: - Date Group

struct DateGroup: Identifiable {
    let date: String
    let sessions: [SessionSummary]
    let displayDate: String    // ⭐️ 預算好的顯示日期（避免 ForEach 裡重複呼叫 formatDateHeader）
    let totalConversations: Int
    var id: String { date }
}

// MARK: - Date Chip View

private struct DateChipView: View {
    let dateString: String
    let displayDate: String
    let sessionCount: Int
    let messageCount: Int
    let isExpanded: Bool
    var isFavorited: Bool = false
    var favoriteName: String? = nil
    var onStarTapped: (() -> Void)? = nil
    var onStarLongPressed: (() -> Void)? = nil
    var onExpandTapped: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .font(.system(size: 16))
                .foregroundStyle(isFavorited ? .orange : .gray.opacity(0.5))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .onTapGesture { onStarTapped?() }
                .onLongPressGesture { onStarLongPressed?() }

            Button(action: { onExpandTapped?() }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(displayDate).font(.subheadline).fontWeight(.semibold)
                            if let name = favoriteName {
                                Text(name)
                                    .font(.caption2).fontWeight(.medium)
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12)).cornerRadius(6)
                            }
                        }
                        Text("\(sessionCount)次通話 · \(messageCount)則訊息")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isExpanded ? Color.blue.opacity(0.08) : Color(.systemBackground))
        )
        .padding(.horizontal, 12).padding(.vertical, 2)
    }
}

// MARK: - Session Divider View

private struct SessionDividerView: View {
    let text: String; let languagePair: String; let time: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                line
                Text(time).font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                line
            }
            .padding(.horizontal, 20).padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: "phone.fill").font(.system(size: 9))
                Text(languagePair); Text("·"); Text(text)
            }
            .font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 4)
        }
    }
    private var line: some View {
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
    }
}

// MARK: - Conversation Bubble

private struct ConversationBubble: View {
    let conversation: ConversationItem
    private var isRight: Bool { conversation.position == "right" }

    var body: some View {
        HStack {
            if isRight { Spacer(minLength: 40) }
            VStack(alignment: isRight ? .trailing : .leading, spacing: 3) {
                Text(conversation.original)
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isRight ? Color.blue.opacity(0.12) : Color(.systemGray5))
                    .cornerRadius(14)
                if !conversation.translated.isEmpty {
                    Text(conversation.translated)
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
            }
            if !isRight { Spacer(minLength: 40) }
        }
    }
}
