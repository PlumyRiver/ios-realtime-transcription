//
//  SessionHistoryView.swift
//  ios_realtime_trans
//
//  過往對話紀錄（日期選擇 → 展開當天對話）
//

import SwiftUI

struct SessionHistoryView: View {
    let uid: String
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = false
    @State private var isComplete = false
    @State private var errorMessage: String?
    @State private var expandedDate: String?
    /// ⭐️ 展開時快取解析好的對話（避免重複解析）
    @State private var conversationCache: [String: [ConversationItem]] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty && !isLoading {
                    emptyState
                } else {
                    dateList
                }
            }
            .navigationTitle("對話紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                isLoading = true
                await SessionService.shared.loadAllSessions(uid: uid) { loaded, complete in
                    sessions = loaded
                    isComplete = complete
                    isLoading = !complete
                }
                isLoading = false
                isComplete = true
            }
        }
    }

    // MARK: - Date List

    private var dateList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // ⭐️ 頂部狀態列
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("載入中… \(sessions.count) 筆 / \(groupedSessions.count) 天")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                ForEach(groupedSessions) { group in
                    // 日期卡片（永遠顯示）
                    DateChipView(
                        dateString: group.date,
                        displayDate: formatDateHeader(group.date),
                        sessionCount: group.sessions.count,
                        messageCount: group.totalConversations,
                        isExpanded: expandedDate == group.date
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if expandedDate == group.date {
                                expandedDate = nil
                            } else {
                                expandedDate = group.date
                            }
                        }
                    }
                    // 展開的對話內容
                    if expandedDate == group.date {
                        expandedContent(for: group)
                            .transition(.opacity)
                    }
                }

                // 底部：全部載完
                if isComplete && !sessions.isEmpty {
                    Text("共 \(sessions.count) 筆 · \(groupedSessions.count) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { idx, session in
                // Session 分隔線
                SessionDividerView(
                    text: session.sessionDividerText,
                    languagePair: session.languagePair,
                    time: session.formattedTime
                )

                // ⭐️ 用快取取得對話（只在第一次展開時解析）
                let convs = cachedConversations(for: session)

                if convs.isEmpty {
                    Text("（無對話內容）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(convs.enumerated()), id: \.offset) { _, conv in
                            ConversationBubble(conversation: conv)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    /// 取得（或快取）某 session 的對話內容
    /// 優先用記憶體快取 → 再試 rawConversations 解析 → 最後從 Firestore 按需抓
    private func cachedConversations(for session: SessionSummary) -> [ConversationItem] {
        if let cached = conversationCache[session.id] {
            return cached
        }

        // 嘗試從 rawConversations 解析（完整 session 有這個資料）
        let parsed = session.parseConversations()
        if !parsed.isEmpty {
            DispatchQueue.main.async { conversationCache[session.id] = parsed }
            return parsed
        }

        // rawConversations 空的（磁碟快取載入的 session）→ 按需從 Firestore 抓
        if session.conversationCount > 0 {
            Task {
                do {
                    let convs = try await SessionService.shared.fetchConversations(
                        uid: uid, sessionId: session.id
                    )
                    conversationCache[session.id] = convs
                    print("📥 [History] 按需載入對話: \(session.id) → \(convs.count) 筆")
                } catch {
                    print("❌ [History] 按需載入對話失敗: \(error.localizedDescription)")
                }
            }
            // 先回傳空，Task 完成後 @State 更新會觸發重繪
            return []
        }

        return []
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("尚無對話紀錄")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("開始錄音對話後，紀錄會自動保存到這裡")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .padding(40)
    }

    // MARK: - Date Formatting

    private func formatDateHeader(_ dateString: String) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"

        guard let date = formatter.date(from: dateString) else { return dateString }

        if calendar.isDateInToday(date) {
            return "今天"
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            let wf = DateFormatter()
            wf.locale = Locale(identifier: "zh-TW")
            wf.dateFormat = "EEEE"
            return wf.string(from: date)
        } else {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh-TW")
            df.dateFormat = "M月d日 EEEE"
            return df.string(from: date)
        }
    }

    // MARK: - Grouping

    private var groupedSessions: [DateGroup] {
        let grouped = Dictionary(grouping: sessions) { $0.formattedDate }
        return grouped.map { DateGroup(date: $0.key, sessions: $0.value) }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Data Loading (由 SessionService.loadAllSessions 處理)
}

// MARK: - Date Group

private struct DateGroup: Identifiable {
    let date: String
    let sessions: [SessionSummary]
    var id: String { date }

    var totalConversations: Int {
        sessions.reduce(0) { $0 + $1.conversationCount }
    }
}

// MARK: - Date Chip View

private struct DateChipView: View {
    let dateString: String
    let displayDate: String
    let sessionCount: Int
    let messageCount: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 日期文字
            VStack(alignment: .leading, spacing: 2) {
                Text(displayDate)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("\(sessionCount)次通話 · \(messageCount)則訊息")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 展開指示
            Image(systemName: "chevron.down")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? -180 : 0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isExpanded ? Color.blue.opacity(0.08) : Color(.systemBackground))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

// MARK: - Session Divider View

private struct SessionDividerView: View {
    let text: String
    let languagePair: String
    let time: String

    var body: some View {
        VStack(spacing: 4) {
            // 分隔線
            HStack(spacing: 8) {
                line
                Text(time)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                line
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // 通話資訊
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 9))
                Text(languagePair)
                Text("·")
                Text(text)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isRight ? Color.blue.opacity(0.12) : Color(.systemGray5))
                    .cornerRadius(14)

                if !conversation.translated.isEmpty {
                    Text(conversation.translated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            if !isRight { Spacer(minLength: 40) }
        }
    }
}
