//
//  ContentView.swift
//  ios_realtime_trans
//
//  Chirp3 即時語音轉錄 iOS 版本
//

import SwiftUI
import UIKit

/// ⭐️ 用於追蹤 ScrollView 滾動位置的 PreferenceKey
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    private static var bodyCount = 0
    private static let launchTime = Date()
    static func _printBodyEval() {
        bodyCount += 1
        let ms = Int(Date().timeIntervalSince(launchTime) * 1000)
        print("⏱️ [ContentView.body] 第 \(bodyCount) 次 @ \(ms)ms")
    }

    @State private var viewModel = TranscriptionViewModel()
    @State private var showSettings = false
    @State private var showHistory = false

    /// ⭐️ 獲取登入用戶資訊
    @State private var authService = AuthService.shared

    /// ⭐️ 是否已經預取過 token（防止重複預取）
    @State private var hasPreFetchedToken = false

    var body: some View {
        let _ = Self._printBodyEval()  // ⏱️ 計時：ContentView.body 被呼叫
        NavigationStack {
            VStack(spacing: 0) {
                ConversationListView(viewModel: viewModel).equatable()

                BottomControlBar(viewModel: viewModel)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左：垃圾桶（獨立）
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.clearTranscriptsOnly()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                // 中：歷史 + 額度
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16))
                        }

                        CreditsToolbarView(showSettings: $showSettings, isRecording: viewModel.isRecording)
                    }
                }

                // 右：設定（獨立）
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(isPresented: $showHistory) {
                if let uid = authService.currentUser?.uid {
                    SessionHistoryView(uid: uid)
                } else {
                    Text("請先登入以查看對話紀錄")
                        .foregroundStyle(.secondary)
                }
            }
            // ⭐️ 額度不足對話框
            .alert("額度已使用完畢", isPresented: $viewModel.showCreditsExhaustedAlert) {
                Button("購買額度") {
                    showSettings = true
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("請購買額度以繼續使用語音翻譯服務")
            }
            // ⭐️ 第一幀渲染後才執行（.task 在 onAppear 之後、第一幀之後觸發）
            .task {
                // 1) ViewModel 延遲初始化（Combine 訂閱 + 服務同步，分段 yield 不阻塞 UI）
                await viewModel.deferredSetup()

                // 2) 背景預載（只執行一次）
                if !hasPreFetchedToken {
                    hasPreFetchedToken = true
                    viewModel.prefetchElevenLabsToken()
                    if let uid = authService.currentUser?.uid {
                        Task.detached(priority: .utility) {
                            async let f: () = SessionService.shared.loadFavorites(uid: uid)
                            async let h: () = SessionService.shared.loadAllSessions(uid: uid) { _, _ in }
                            _ = await (f, h)
                            print("⚡️ [Preload] 對話歷史 + 收藏預載完成")
                        }
                    }
                }
                print("💰 [ContentView] currentUser = \(authService.currentUser?.email ?? "nil"), slowCredits = \(authService.currentUser?.slowCredits ?? -1)")
            }
            // ⭐️ 編輯對話 Sheet（狀態在 ViewModel 中，不觸發 ContentView 重繪）
            .sheet(isPresented: $viewModel.showEditSheet) {
                EditTranscriptSheet(
                    initialText: viewModel.editingInitialText,
                    onConfirm: { newText in
                        if let id = viewModel.editingTranscriptId {
                            viewModel.editTranscriptAndRetranslate(id: id, newText: newText)
                        }
                        viewModel.showEditSheet = false
                    },
                    onCancel: {
                        viewModel.showEditSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }
}

// MARK: - Conversation List View（獨立子視圖，隔離 ContentView 的 @State 重繪）
/// ⭐️ 關鍵：這個 View 只依賴 viewModel（@Observable），不依賴 ContentView 的任何 @State。
/// 當 showSettings/showHistory 等 ContentView @State 變化時，SwiftUI 重算 ContentView.body，
/// 但因為 ConversationListView 的唯一輸入 viewModel（引用）沒變，SwiftUI 跳過此 View 的 body 重算。

struct ConversationListView: View, Equatable {
    var viewModel: TranscriptionViewModel
    @State private var isUserScrolledUp = false

    private static var bodyCount = 0
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        let _ = { Self.bodyCount += 1; print("⏱️ [ConversationList.body] 第 \(Self.bodyCount) 次, transcripts=\(viewModel.transcripts.count)") }()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.transcripts) { transcript in
                        ConversationBubbleView(
                            transcript: transcript,
                            sourceLang: viewModel.sourceLang,
                            targetLang: viewModel.targetLang,
                            onPlayTTS: { text, langCode in
                                viewModel.playTTSImmediately(text: text, languageCode: langCode)
                            },
                            onStopTTS: {
                                viewModel.skipCurrentTTS()
                            },
                            currentPlayingText: viewModel.currentPlayingTTSText,
                            onDelete: {
                                viewModel.deleteTranscript(id: transcript.id)
                            },
                            onEditTapped: {
                                viewModel.startEditing(transcript: transcript)
                            }
                        )
                        .id(transcript.id)
                    }

                    if let interim = viewModel.interimTranscript {
                        ConversationBubbleView(
                            transcript: interim,
                            sourceLang: viewModel.sourceLang,
                            targetLang: viewModel.targetLang,
                            onPlayTTS: { text, langCode in
                                viewModel.playTTSImmediately(text: text, languageCode: langCode)
                            },
                            onStopTTS: {
                                viewModel.skipCurrentTTS()
                            },
                            currentPlayingText: viewModel.currentPlayingTTSText
                        )
                        .id("interim")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                }
                .padding()
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geometry.frame(in: .named("scrollView")).maxY
                            )
                    }
                )
            }
            .coordinateSpace(name: "scrollView")
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 30 {
                            if !isUserScrolledUp {
                                isUserScrolledUp = true
                                print("📜 [Scroll] 用戶開始查看舊訊息")
                            }
                        }
                    }
            )
            .onChange(of: viewModel.transcripts.count) { _, _ in
                guard !isUserScrolledUp else { return }
                if let lastId = viewModel.transcripts.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.interimTranscript) { _, _ in
                guard !isUserScrolledUp else { return }
                withAnimation { proxy.scrollTo("interim", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if isUserScrolledUp {
                    Button {
                        isUserScrolledUp = false
                        withAnimation {
                            if viewModel.interimTranscript != nil {
                                proxy.scrollTo("interim", anchor: .bottom)
                            } else if let lastId = viewModel.transcripts.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            } else {
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                            Text("新訊息")
                                .font(.system(size: 15, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                        )
                    }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.2), value: isUserScrolledUp)
                }
            }
        }
    }
}

// MARK: - Conversation Bubble View (社群軟體風格)

struct ConversationBubbleView: View {
    let transcript: TranscriptMessage
    let sourceLang: Language  // 用戶設定的來源語言
    let targetLang: Language  // 用戶設定的目標語言
    /// ⭐️ 使用 ViewModel 的統一播放方法（通過 AudioManager，啟用 AEC）
    var onPlayTTS: ((String, String) -> Void)?
    /// ⭐️ 停止當前 TTS 並播放下一個
    var onStopTTS: (() -> Void)?
    /// ⭐️ 當前正在播放的 TTS 文本（用於判斷是否顯示停止按鈕）
    var currentPlayingText: String?
    /// ⭐️ 刪除這則對話
    var onDelete: (() -> Void)?
    /// ⭐️ 點擊編輯按鈕（由父層處理 sheet 顯示）
    var onEditTapped: (() -> Void)?

    /// ⭐️ 判斷這句話是否正在播放
    private var isThisPlaying: Bool {
        guard let translation = transcript.translation,
              let playingText = currentPlayingText else {
            return false
        }
        return translation == playingText
    }

    /// 判斷是否為來源語言（用戶說的話）
    /// 根據 Chirp3 返回的語言代碼與用戶設定的來源語言比較
    private var isSourceLanguage: Bool {
        guard let detectedLang = transcript.language else { return true }
        let detectedBase = detectedLang.split(separator: "-").first.map(String.init) ?? detectedLang
        return detectedBase == sourceLang.rawValue
    }

    /// ⭐️ 獲取 TTS 語言代碼
    /// 一般對話：播放翻譯（語言與原文相反）
    /// 介紹提示：播放原文本身（語言與原文相同）
    private var ttsLanguageCode: String {
        if transcript.isIntroduction {
            // ⭐️ 介紹提示：播放原文語言
            return isSourceLanguage ? sourceLang.azureLocale : targetLang.azureLocale
        }
        if isSourceLanguage {
            return targetLang.azureLocale
        } else {
            return sourceLang.azureLocale
        }
    }

    /// 氣泡背景顏色
    private var bubbleColor: Color {
        if isSourceLanguage {
            // 來源語言（用戶）：藍色
            return Color.blue
        } else {
            // 目標語言（對方）：灰色
            return Color(.systemGray5)
        }
    }

    /// 文字顏色
    private var textColor: Color {
        isSourceLanguage ? .white : .primary
    }

    /// 次要文字顏色
    private var secondaryTextColor: Color {
        isSourceLanguage ? .white.opacity(0.8) : .secondary
    }

    /// 是否顯示控制按鈕（播放 + 複製 + 刪除）
    /// ⭐️ 修復：所有 final 都顯示按鈕（至少可以刪除和複製）
    private var showControlButtons: Bool {
        transcript.isFinal
    }

    /// ⭐️ 是否有可播放的翻譯
    private var hasPlayableTranslation: Bool {
        transcript.translation != nil && !transcript.translation!.isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左邊留空（來源語言在右側）
            if isSourceLanguage {
                Spacer()
            }

            // 控制按鈕（左側，僅來源語言/右邊氣泡顯示）
            if isSourceLanguage && showControlButtons {
                controlButtons
            }

            // 對話氣泡內容
            bubbleContent

            // 控制按鈕（右側，僅目標語言/左邊氣泡顯示）
            if !isSourceLanguage && showControlButtons {
                controlButtons
            }

            // 右邊留空（目標語言在左側）
            if !isSourceLanguage {
                Spacer()
            }
        }
        // ⭐️ 不再使用透明度區分 interim/final，讓所有氣泡看起來一樣
    }

    /// ⭐️ 對話框固定寬度（螢幕寬度的 70%）
    private var bubbleFixedWidth: CGFloat {
        UIScreen.main.bounds.width * 0.70
    }

    /// 氣泡內容
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 原文（⭐️ 不再區分 interim/final 的顏色）
            Text(transcript.text)
                .font(.body)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)  // ⭐️ 允許垂直擴展，水平固定

            // 翻譯（較小字體）— 介紹提示不顯示（translation 僅用於觸發按鈕和 TTS）
            // ⭐️ 關鍵：使用固定容器避免新舊翻譯切換時的空白閃爍
            if !transcript.isIntroduction,
               let translation = transcript.translation, !translation.isEmpty {
                Text(translation)
                    .font(.subheadline)
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)  // ⭐️ 允許垂直擴展
                    .id("translation-\(transcript.id)")  // ⭐️ 保持視圖身份穩定
                    .transition(.identity)  // ⭐️ 無過渡動畫，直接替換
            }

            // 元數據行（⭐️ 簡化：不顯示 TypingIndicator，interim 和 final 看起來完全一樣）
            HStack(spacing: 6) {
                if let language = transcript.language {
                    Text(languageDisplayName(language))
                        .font(.caption2)
                }

                if transcript.confidence > 0 {
                    Text("·")
                    Text("\(Int(transcript.confidence * 100))%")
                        .font(.caption2)
                }
            }
            .foregroundStyle(isSourceLanguage ? Color.white.opacity(0.6) : Color.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: bubbleFixedWidth, alignment: .leading)  // ⭐️ 固定寬度
        .background(bubbleColor)
        .cornerRadius(18)
        // ⭐️ 禁用翻譯更新時的動畫，避免空白閃爍
        .animation(nil, value: transcript.translation)
    }

    /// 控制按鈕組（播放 + 複製 + 刪除）
    private var controlButtons: some View {
        VStack(spacing: 6) {
            // ⭐️ 播放/停止按鈕（僅在有翻譯時顯示）
            if hasPlayableTranslation {
                Button {
                    if isThisPlaying {
                        // 正在播放這句 → 停止並播放下一個
                        onStopTTS?()
                    } else {
                        // 沒在播放 → 開始播放
                        // ⭐️ 使用 ttsLanguageCode 根據原文語言動態決定 TTS 語言
                        onPlayTTS?(transcript.translation!, ttsLanguageCode)
                    }
                } label: {
                    Image(systemName: isThisPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isThisPlaying ? .red : .blue)
                }
            }

            // 編輯按鈕
            Button {
                onEditTapped?()
            } label: {
                Image(systemName: "pencil")
                    .font(.title3)
                    .foregroundStyle(.gray)
            }

            // 刪除按鈕
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onDelete?()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(.gray)
            }
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let names: [String: String] = [
            "zh": "中文",
            "en": "English",
            "ja": "日本語",
            "ko": "한국어",
            "es": "Español",
            "fr": "Français",
            "de": "Deutsch",
            "it": "Italiano",
            "pt": "Português",
            "ru": "Русский",
            "ar": "العربية",
            "hi": "हिन्दी",
            "th": "ไทย",
            "vi": "Tiếng Việt"
        ]
        return names[base] ?? code
    }

}

// MARK: - 編輯對話 Sheet

struct EditTranscriptSheet: View {
    /// ⭐️ 只接收初始值（plain String），不用 @Binding 連回父層
    /// 這樣 TextField 輸入不會觸發 ContentView 重新渲染整個對話列表
    let initialText: String
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 頂部按鈕列
            HStack {
                Button("取消") { onCancel() }
                    .foregroundStyle(.blue)
                Spacer()
                Text("編輯對話")
                    .font(.headline)
                Spacer()
                Button("確認翻譯") { onConfirm(text) }
                    .bold()
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Text("編輯文字後將重新翻譯")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            TextField("輸入文字", text: $text, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .focused($isFocused)
                .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            text = initialText
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isFocused = true
            }
        }
    }
}

// MARK: - Bubble Tail Shape (氣泡尖角)

struct BubbleTail: Shape {
    let isRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isRight {
            // 右側尖角
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
        } else {
            // 左側尖角
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Typing Indicator (輸入中指示器)

struct TypingIndicator: View {
    @State private var animationPhase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever()
                        .delay(Double(index) * 0.15),
                        value: animationPhase
                    )
            }
        }
        .onAppear {
            animationPhase = 2
        }
    }
}

// MARK: - Bottom Control Bar (底部控制區 - 兩排架構)

struct BottomControlBar: View {
    @Bindable var viewModel: TranscriptionViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 16) {
                // === 第一行：語言選擇器 + 模式切換 ===
                LanguageSelectorRow(viewModel: viewModel)

                // === 第二行：根據通話狀態顯示不同內容 ===
                if viewModel.isRecording {
                    // 通話中：TTS + 錄音 + 結束通話
                    InCallControlRow(viewModel: viewModel)
                } else {
                    // 未通話：滑動開始通話
                    CenteredCallButton(viewModel: viewModel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // ⭐️ 底部不加 padding，讓按鈕標籤貼近螢幕最下方
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - 通話中控制行（TTS + 錄音 居中，結束通話在右側）

struct InCallControlRow: View {
    @Bindable var viewModel: TranscriptionViewModel

    // 結束通話滑動狀態
    @State private var isEndCallPressed = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    // Haptic
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

    // 按鈕尺寸（與原本 DualIconControlRow 一致）
    private let buttonSize: CGFloat = 70
    private let iconSize: CGFloat = 28
    private let endCallButtonSize: CGFloat = 60  // ⭐️ 與開始通話滑塊一樣大

    // 滑軌尺寸
    private let sliderHeight: CGFloat = 70
    private let thumbSize: CGFloat = 60
    private let threshold: CGFloat = 0.6

    var body: some View {
        GeometryReader { geometry in
            let sliderWidth = geometry.size.width

            ZStack {
                // 正常狀態：TTS + 錄音 真正居中，結束通話用 overlay 放右側
                if !isEndCallPressed {
                    // ⭐️ 根據經濟模式切換 UI
                    if viewModel.isEconomyMode {
                        // 經濟模式：TTS + 單麥克風（按住錄音，放開比較兩種語言）
                        HStack(spacing: 40) {
                            ttsButton
                            economySingleMicButton
                        }
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            endCallButton
                                .padding(.trailing, 4)
                        }
                        .transition(.opacity)
                    } else {
                        // 一般模式：TTS + 單麥克風
                        HStack(spacing: 40) {
                            ttsButton
                            microphoneButton
                        }
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            endCallButton
                                .padding(.trailing, 4)
                        }
                        .transition(.opacity)
                    }
                } else {
                    // 滑動軌道（填滿整個寬度）
                    endCallSlider(width: sliderWidth)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isEndCallPressed)
        }
        .frame(height: 100)  // ⭐️ 給標籤留空間
        .onAppear {
            hapticGenerator.prepare()
        }
    }

    // MARK: - TTS 按鈕

    private var ttsButtonColor: Color {
        switch viewModel.ttsPlaybackMode {
        case .all: return .green
        case .sourceOnly: return .blue
        case .targetOnly: return .orange
        case .muted: return Color(.systemGray4)
        }
    }

    private var isTTSActive: Bool {
        viewModel.ttsPlaybackMode != .muted
    }

    private var ttsButton: some View {
        Button {
            viewModel.ttsPlaybackMode = viewModel.ttsPlaybackMode.next()
            hapticGenerator.impactOccurred()
        } label: {
            ZStack {
                Circle()
                    .fill(isTTSActive ? ttsButtonColor.opacity(0.15) : Color(.systemGray6))
                    .frame(width: buttonSize, height: buttonSize)

                Circle()
                    .fill(ttsButtonColor)
                    .frame(width: buttonSize - 10, height: buttonSize - 10)
                    .shadow(color: isTTSActive ? ttsButtonColor.opacity(0.3) : .clear, radius: 8)

                Image(systemName: viewModel.ttsPlaybackMode.iconName)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            Text(viewModel.ttsPlaybackMode.displayText(
                sourceLang: viewModel.sourceLang,
                targetLang: viewModel.targetLang
            ))
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(isTTSActive ? ttsButtonColor : .secondary)
            .offset(y: 28)
        }
    }

    // MARK: - 錄音按鈕

    @State private var pulseAnimation = false
    @State private var isPressed = false

    private var isVADMode: Bool {
        viewModel.inputMode == .vad
    }

    // ⭐️ 聲波動畫相位（多條聲波各自不同速度）
    @State private var wavePhase1: Bool = false
    @State private var wavePhase2: Bool = false
    @State private var wavePhase3: Bool = false

    private var microphoneButton: some View {
        ZStack {
            if isVADMode {
                // VAD 模式：快速擴散波紋 + 跳動聲波條
                ZStack {
                    // 三層快速擴散波紋（交錯發射）
                    Circle()
                        .stroke(Color.green.opacity(0.5), lineWidth: 2.5)
                        .frame(width: buttonSize + 10, height: buttonSize + 10)
                        .scaleEffect(pulseAnimation ? 1.6 : 1.0)
                        .opacity(pulseAnimation ? 0.0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulseAnimation)

                    Circle()
                        .stroke(Color.green.opacity(0.4), lineWidth: 2)
                        .frame(width: buttonSize + 10, height: buttonSize + 10)
                        .scaleEffect(pulseAnimation ? 1.5 : 0.95)
                        .opacity(pulseAnimation ? 0.0 : 0.5)
                        .animation(.easeOut(duration: 1.2).delay(0.4).repeatForever(autoreverses: false), value: pulseAnimation)

                    Circle()
                        .stroke(Color.green.opacity(0.3), lineWidth: 1.5)
                        .frame(width: buttonSize + 10, height: buttonSize + 10)
                        .scaleEffect(pulseAnimation ? 1.4 : 0.9)
                        .opacity(pulseAnimation ? 0.0 : 0.4)
                        .animation(.easeOut(duration: 1.2).delay(0.8).repeatForever(autoreverses: false), value: pulseAnimation)

                    // 發光底色
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.green, Color.green.opacity(0.7)],
                                center: .center,
                                startRadius: 0,
                                endRadius: 35
                            )
                        )
                        .frame(width: buttonSize - 10, height: buttonSize - 10)
                        .shadow(color: Color.green.opacity(0.6), radius: 14)
                        .shadow(color: Color.green.opacity(0.3), radius: 25)

                    // 7 條快速跳動聲波條
                    HStack(spacing: 2.5) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.white)
                                .frame(
                                    width: 3,
                                    height: [wavePhase1, wavePhase2, wavePhase3, wavePhase1, wavePhase2, wavePhase3, wavePhase1][i]
                                        ? [24, 14, 28, 10, 22, 16, 26][i]
                                        : [8, 20, 6, 24, 10, 22, 8][i]
                                )
                        }
                    }
                    .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: wavePhase1)
                    .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: wavePhase2)
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: wavePhase3)
                }
                .onAppear {
                    pulseAnimation = false
                    wavePhase1 = false
                    wavePhase2 = false
                    wavePhase3 = false
                    DispatchQueue.main.async {
                        pulseAnimation = true
                        wavePhase1 = true
                        wavePhase2 = true
                        wavePhase3 = true
                    }
                }
            } else {
                // PTT 模式：按住說話
                ZStack {
                    Circle()
                        .fill(isPressed ? Color.red.opacity(0.2) : Color(.systemGray6))
                        .frame(width: buttonSize, height: buttonSize)
                        .scaleEffect(isPressed ? 1.15 : 1.0)

                    Circle()
                        .fill(isPressed ? Color.red : Color.orange)
                        .frame(width: buttonSize - 10, height: buttonSize - 10)
                        .shadow(color: isPressed ? Color.red.opacity(0.5) : Color.orange.opacity(0.3), radius: 8)

                    Image(systemName: isPressed ? "mic.fill" : "mic")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(.white)
                }
                .scaleEffect(isPressed ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: isPressed)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressed {
                                isPressed = true
                                viewModel.startTalking()
                                hapticGenerator.impactOccurred()
                            }
                        }
                        .onEnded { _ in
                            isPressed = false
                            viewModel.stopTalking()
                        }
                )
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                Text(isVADMode ? "收音中" : (isPressed ? "錄音中" : "按住說話"))
                    .font(.caption2)
                    .fontWeight(.medium)
                if isVADMode {
                    Text("Listening")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(isVADMode ? .green : (isPressed ? .red : .secondary))
            .offset(y: 28)
        }
    }

    // MARK: - ⭐️ 經濟模式單麥克風按鈕（按住錄音，放開比較兩種語言）

    @State private var isEconomyMicPressed = false

    private var economySingleMicButton: some View {
        ZStack {
            // 外圈（按住時光暈）- 與一般模式相同
            Circle()
                .fill(isEconomyMicPressed ? Color.red.opacity(0.2) : Color(.systemGray6))
                .frame(width: buttonSize, height: buttonSize)
                .scaleEffect(isEconomyMicPressed ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: isEconomyMicPressed)

            // 主圈 - 使用橙色（與一般 PTT 相同）
            Circle()
                .fill(isEconomyMicPressed ? Color.red : Color.orange)
                .frame(width: buttonSize - 10, height: buttonSize - 10)
                .shadow(
                    color: isEconomyMicPressed ? Color.red.opacity(0.5) : Color.orange.opacity(0.3),
                    radius: isEconomyMicPressed ? 12 : 6,
                    x: 0, y: 2
                )

            // 麥克風圖標
            Image(systemName: isEconomyMicPressed ? "mic.fill" : "mic")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .scaleEffect(isEconomyMicPressed ? 1.1 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isEconomyMicPressed)
        }
        .scaleEffect(isEconomyMicPressed ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isEconomyMicPressed)
        .overlay(alignment: .bottom) {
            // 顯示語言對
            VStack(spacing: 1) {
                Text(isEconomyMicPressed ? "錄音中" : "按住說話")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(isEconomyMicPressed ? .red : .secondary)

                Text("\(viewModel.sourceLang.shortName) ↔ \(viewModel.targetLang.shortName)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .offset(y: 28)
        }
        // 按住錄音手勢
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isEconomyMicPressed {
                        isEconomyMicPressed = true
                        hapticGenerator.impactOccurred()
                        // 開始錄音
                        viewModel.startEconomyRecording()
                    }
                }
                .onEnded { _ in
                    isEconomyMicPressed = false
                    hapticGenerator.impactOccurred()
                    // 停止錄音，觸發雙語言比較
                    viewModel.stopEconomyRecordingAndCompare()
                }
        )
    }

    // MARK: - 結束通話按鈕（右側）

    private var endCallButton: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.15))
                .frame(width: endCallButtonSize, height: endCallButtonSize)

            Circle()
                .fill(Color.red)
                .frame(width: endCallButtonSize - 8, height: endCallButtonSize - 8)
                .shadow(color: Color.red.opacity(0.3), radius: 6)

            Image(systemName: "phone.down.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            Text("結束")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.red)
                .offset(y: 28)
        }
        // ⭐️ 一碰到就觸發滑動條（不用等點擊完成）
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isEndCallPressed {
                        isEndCallPressed = true
                        hapticGenerator.impactOccurred()
                    }
                }
        )
    }

    // MARK: - 結束通話滑動軌道（填滿整個寬度）

    private func endCallSlider(width: CGFloat) -> some View {
        let maxOffset = width - thumbSize - 20

        return ZStack {
            // 背景軌道
            RoundedRectangle(cornerRadius: sliderHeight / 2)
                .fill(Color.red.opacity(0.15))
                .frame(width: width, height: sliderHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: sliderHeight / 2)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                )

            // 左邊圖標（結束目標）
            HStack {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.leading, 20)
                Spacer()
            }

            // 提示文字
            Text("← 滑動結束通話")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            // 可滑動按鈕（從右側開始）
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.pink, Color.red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .red.opacity(0.4), radius: 8, y: 4)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                )
                .scaleEffect(isDragging ? 1.1 : 1.0)
                .animation(.spring(response: 0.3), value: isDragging)
                .offset(x: (width - thumbSize) / 2 - 10 + dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            isDragging = true
                            // 只能往左滑
                            dragOffset = min(0, max(-maxOffset, value.translation.width))
                        }
                        .onEnded { _ in
                            isDragging = false
                            let progress = abs(dragOffset) / maxOffset

                            if progress > threshold {
                                // 觸發結束通話
                                hapticGenerator.impactOccurred()

                                // ⭐️ 同步更新 UI（立即切換畫面）
                                viewModel.endCall()

                                // 重置狀態
                                dragOffset = 0
                                isEndCallPressed = false
                            } else {
                                // 未達閾值，彈回原位
                                withAnimation(.spring(response: 0.3)) {
                                    dragOffset = 0
                                    isEndCallPressed = false
                                }
                            }
                        }
                )
        }
        .onTapGesture {
            // 點擊空白處取消
            withAnimation {
                isEndCallPressed = false
            }
        }
    }
}

// MARK: - 語言選擇器行（含模式切換）

struct LanguageSelectorRow: View {
    @Bindable var viewModel: TranscriptionViewModel

    // 控制全螢幕語言選擇器
    @State private var showSourcePicker = false
    @State private var showTargetPicker = false

    var body: some View {
        HStack(spacing: 12) {
            // 語言選擇器
            HStack(spacing: 8) {
                // 來源語言按鈕
                Button {
                    showSourcePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.sourceLang.flag)
                            .font(.title3)
                        Text(viewModel.sourceLang.shortName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.primary)
                }
                .disabled(viewModel.isRecording)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 目標語言按鈕
                Button {
                    showTargetPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.targetLang.flag)
                            .font(.title3)
                        Text(viewModel.targetLang.shortName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.primary)
                }
                .disabled(viewModel.isRecording)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(20)
            .opacity(viewModel.isRecording ? 0.6 : 1.0)

            Spacer()

            // ⭐️ 模式切換開關（仿開講AI設計）
            InputModeToggle(viewModel: viewModel)
        }
        // 來源語言全螢幕選擇器
        .fullScreenCover(isPresented: $showSourcePicker) {
            LanguagePickerSheet(
                selectedLanguage: Binding(
                    get: { viewModel.sourceLang },
                    set: { viewModel.sourceLang = $0 }
                ),
                title: "選擇來源語言",
                includeAuto: true
            )
        }
        // 目標語言全螢幕選擇器
        .fullScreenCover(isPresented: $showTargetPicker) {
            LanguagePickerSheet(
                selectedLanguage: Binding(
                    get: { viewModel.targetLang },
                    set: { viewModel.targetLang = $0 }
                ),
                title: "選擇目標語言",
                includeAuto: false
            )
        }
    }
}

// MARK: - 模式切換開關

struct InputModeToggle: View {
    @Bindable var viewModel: TranscriptionViewModel

    var body: some View {
        HStack(spacing: 2) {
            // VAD 模式（持續翻譯）
            Button {
                viewModel.inputMode = .vad
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.caption)
                    Text("持續")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(viewModel.isVADMode ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(viewModel.isVADMode ? Color.green : Color.clear)
                .cornerRadius(14)
            }

            // PTT 模式（按住說話）
            Button {
                viewModel.inputMode = .ptt
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap")
                        .font(.caption)
                    Text("按住")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(!viewModel.isVADMode ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(!viewModel.isVADMode ? Color.orange : Color.clear)
                .cornerRadius(14)
            }
        }
        .padding(3)
        .background(Color(.systemGray5))
        .cornerRadius(17)
    }
}

// MARK: - 喇叭 + 麥克風 並排居中控制區（仿開講AI）

struct DualIconControlRow: View {
    @Bindable var viewModel: TranscriptionViewModel
    @State private var isPressed: Bool = false
    @State private var pulseAnimation: Bool = false

    /// ⭐️ 預先初始化 Haptic Feedback Generator，避免第一次點擊延遲
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    /// 按鈕尺寸（兩者相同）
    private let buttonSize: CGFloat = 80
    private let iconSize: CGFloat = 32

    /// 是否為 VAD 模式
    private var isVADMode: Bool { viewModel.isVADMode }

    /// 是否正在發送音頻
    private var isSending: Bool { isVADMode || isPressed }

    var body: some View {
        VStack(spacing: 12) {
            // 狀態指示（僅在發送時顯示）
            if isSending {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isVADMode ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1.0)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isSending)

                    Text(isVADMode ? "持續監聽中" : "錄音中...")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(isVADMode ? .green : .red)

                    if viewModel.recordingDuration > 0 {
                        Text(formatDuration(viewModel.recordingDuration))
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background((isVADMode ? Color.green : Color.red).opacity(0.1))
                .cornerRadius(16)
            }

            // ⭐️ 喇叭 + 麥克風 並排居中
            HStack(spacing: 40) {
                // TTS 播放按鈕
                speakerButton

                // 麥克風按鈕（錄音）
                microphoneButton
            }
            .padding(.bottom, 28)  // ⭐️ 給標籤留空間，避免被通話按鈕遮擋
        }
        .padding(.vertical, 8)
        .onAppear {
            if isVADMode { pulseAnimation = true }
            // ⭐️ 預熱 Haptic Engine，避免第一次點擊延遲
            hapticGenerator.prepare()
        }
        .onChange(of: isVADMode) { _, newValue in
            pulseAnimation = newValue
        }
    }

    // MARK: - TTS 播放按鈕（四段切換：全部 → 只播來源 → 只播目標 → 靜音）

    /// 根據 TTS 播放模式返回對應顏色
    private var ttsButtonColor: Color {
        switch viewModel.ttsPlaybackMode {
        case .all:
            return .green       // 全部播放：綠色
        case .sourceOnly:
            return .blue        // 只播來源：藍色
        case .targetOnly:
            return .orange      // 只播目標：橘色
        case .muted:
            return Color(.systemGray4)  // 靜音：灰色
        }
    }

    /// 根據 TTS 播放模式返回是否活躍
    private var isTTSActive: Bool {
        viewModel.ttsPlaybackMode != .muted
    }

    private var speakerButton: some View {
        Button {
            // ⭐️ 診斷：記錄點擊時間
            let startTime = CFAbsoluteTimeGetCurrent()

            // 切換到下一個 TTS 播放模式
            viewModel.ttsPlaybackMode = viewModel.ttsPlaybackMode.next()

            // ⭐️ 診斷：記錄狀態更新完成時間
            let stateUpdateTime = CFAbsoluteTimeGetCurrent()
            print("⏱️ [TTS按鈕] 狀態更新耗時: \(String(format: "%.3f", (stateUpdateTime - startTime) * 1000))ms")

            // 使用預先初始化的 generator，避免延遲
            hapticGenerator.impactOccurred()

            // ⭐️ 診斷：記錄總耗時
            let endTime = CFAbsoluteTimeGetCurrent()
            print("⏱️ [TTS按鈕] 總耗時: \(String(format: "%.3f", (endTime - startTime) * 1000))ms")
        } label: {
            ZStack {
                // 外圈（活躍時有光暈）
                Circle()
                    .fill(isTTSActive ? ttsButtonColor.opacity(0.15) : Color(.systemGray6))
                    .frame(width: buttonSize, height: buttonSize)

                // 主圈
                Circle()
                    .fill(ttsButtonColor)
                    .frame(width: buttonSize - 10, height: buttonSize - 10)
                    .shadow(color: isTTSActive ? ttsButtonColor.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 2)

                // 圖標（根據模式變化）
                Image(systemName: viewModel.ttsPlaybackMode.iconName)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            // 顯示當前模式名稱（帶具體語言，如「只播英文」）
            Text(viewModel.ttsPlaybackMode.displayText(
                sourceLang: viewModel.sourceLang,
                targetLang: viewModel.targetLang
            ))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(isTTSActive ? ttsButtonColor : .secondary)
                .offset(y: 24)
        }
    }

    // MARK: - 麥克風按鈕

    private var microphoneButton: some View {
        ZStack {
            if isVADMode {
                // VAD 模式：持續監聽動畫
                vadMicButton
            } else {
                // PTT 模式：按住說話
                pttMicButton
            }
        }
        .overlay(alignment: .bottom) {
            Text(isVADMode ? "監聽中" : "按住說話")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(isSending ? (isVADMode ? .green : .red) : .secondary)
                .offset(y: 24)
        }
    }

    // MARK: - VAD 模式麥克風

    private var vadMicButton: some View {
        ZStack {
            // 脈動光暈
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: buttonSize, height: buttonSize)
                .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                .opacity(pulseAnimation ? 0.0 : 0.5)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: pulseAnimation)

            // 主圈
            Circle()
                .fill(Color.green)
                .frame(width: buttonSize - 10, height: buttonSize - 10)
                .shadow(color: Color.green.opacity(0.4), radius: 8, x: 0, y: 2)

            // 波形圖標
            Image(systemName: "waveform")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .scaleEffect(pulseAnimation ? 1.1 : 0.95)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnimation)
        }
    }

    // MARK: - PTT 模式麥克風

    private var pttMicButton: some View {
        ZStack {
            // 外圈（按住時光暈）
            Circle()
                .fill(isPressed ? Color.red.opacity(0.2) : Color(.systemGray6))
                .frame(width: buttonSize, height: buttonSize)
                .scaleEffect(isPressed ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: isPressed)

            // 主圈
            Circle()
                .fill(isPressed ? Color.red : Color.orange)
                .frame(width: buttonSize - 10, height: buttonSize - 10)
                .shadow(
                    color: isPressed ? Color.red.opacity(0.5) : Color.orange.opacity(0.3),
                    radius: isPressed ? 12 : 6,
                    x: 0, y: 2
                )

            // 麥克風圖標
            Image(systemName: isPressed ? "mic.fill" : "mic")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .scaleEffect(isPressed ? 1.1 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isPressed)
        }
        .scaleEffect(isPressed ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        viewModel.startTalking()
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    viewModel.stopTalking()
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - 通話按鈕（填滿整個寬度）

struct CenteredCallButton: View {
    @Bindable var viewModel: TranscriptionViewModel

    // 滑動狀態
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    // 尺寸常數
    private let containerHeight: CGFloat = 100  // ⭐️ 與通話中控制欄高度一致
    private let trackHeight: CGFloat = 70
    private let thumbSize: CGFloat = 60
    private let threshold: CGFloat = 0.6  // 滑動超過 60% 觸發

    // 按鈕顏色
    private var thumbGradient: LinearGradient {
        LinearGradient(
            colors: [Color.green, Color.mint],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let maxOffset = trackWidth - thumbSize - 20

            ZStack {
                // 背景軌道
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.green.opacity(0.15))
                    .frame(height: trackHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )

                // 左邊圖標（麥克風）
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(.green.opacity(0.5))
                        .padding(.leading, 20)
                    Spacer()
                }

                // 右邊圖標（開始通話）
                HStack {
                    Spacer()
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.green.opacity(0.8))
                        .padding(.trailing, 20)
                }

                // 中間提示文字
                Text("滑動開始通話 →")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                // 可滑動的按鈕（從左側開始）
                Circle()
                    .fill(thumbGradient)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .green.opacity(0.4), radius: 8, y: 4)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    )
                    .scaleEffect(isDragging ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isDragging)
                    .offset(x: -(trackWidth - thumbSize) / 2 + 10 + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                // 只能往右滑
                                dragOffset = max(0, min(maxOffset, value.translation.width))
                            }
                            .onEnded { _ in
                                isDragging = false
                                let progress = dragOffset / maxOffset

                                if progress > threshold {
                                    // 觸覺反饋
                                    let generator = UIImpactFeedbackGenerator(style: .medium)
                                    generator.impactOccurred()

                                    // ⭐️ 同步更新 UI（立即切換畫面）
                                    viewModel.beginCall()

                                    // ⭐️ 背景執行連接（不阻塞 UI）
                                    Task.detached {
                                        await viewModel.performStartRecording()
                                    }
                                } else {
                                    // 未達閾值，彈回原位
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(height: containerHeight)  // ⭐️ 與通話中控制欄高度一致
    }
}

// MARK: - 主要麥克風按鈕區（根據模式變化樣式）- 保留備用

struct MainMicrophoneButton: View {
    @Bindable var viewModel: TranscriptionViewModel
    @State private var isPressed: Bool = false
    @State private var pulseAnimation: Bool = false

    /// 是否為 VAD 模式（持續監聽）
    private var isVADMode: Bool {
        viewModel.isVADMode
    }

    /// 是否正在發送音頻
    private var isSending: Bool {
        isVADMode || isPressed
    }

    /// 主要顏色
    private var primaryColor: Color {
        if isVADMode {
            return .green  // VAD 模式：綠色
        } else {
            return isPressed ? .red : .orange  // PTT 模式：橙色/紅色
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // 錄音狀態指示
            statusIndicator

            // 大按鈕（根據模式不同）
            if isVADMode {
                vadModeButton
            } else {
                pttModeButton
            }

            // 提示文字
            Text(isVADMode ? "持續監聽中" : "按住說話")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .onAppear {
            if isVADMode {
                pulseAnimation = true
            }
        }
        .onChange(of: isVADMode) { _, newValue in
            pulseAnimation = newValue
        }
    }

    // MARK: - 狀態指示器

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isSending ? (isVADMode ? Color.green : Color.red) : Color.gray)
                .frame(width: 8, height: 8)
                .scaleEffect(isSending ? 1.0 : 0.8)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isSending)

            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isSending ? (isVADMode ? .green : .red) : .secondary)

            if viewModel.recordingDuration > 0 {
                Text(formatDuration(viewModel.recordingDuration))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSending ? primaryColor.opacity(0.1) : Color(.systemGray6))
        .cornerRadius(16)
    }

    private var statusText: String {
        if isVADMode {
            return "持續監聽中"
        } else {
            return isPressed ? "錄音中..." : "待命中"
        }
    }

    // MARK: - VAD 模式按鈕（持續監聽）

    private var vadModeButton: some View {
        ZStack {
            // 外圈脈動光暈
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 100, height: 100)
                .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                .opacity(pulseAnimation ? 0.0 : 0.5)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: pulseAnimation)

            Circle()
                .fill(Color.green.opacity(0.2))
                .frame(width: 100, height: 100)
                .scaleEffect(pulseAnimation ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseAnimation)

            // 主按鈕
            Circle()
                .fill(Color.green)
                .frame(width: 85, height: 85)
                .shadow(color: Color.green.opacity(0.4), radius: 12, x: 0, y: 4)

            // 波形圖示
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .scaleEffect(pulseAnimation ? 1.1 : 0.95)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnimation)
        }
        .scaleEffect(1.05)
    }

    // MARK: - PTT 模式按鈕（按住說話）

    private var pttModeButton: some View {
        ZStack {
            // 外圈光暈（按住時顯示）
            Circle()
                .fill(isPressed ? Color.red.opacity(0.2) : Color.clear)
                .frame(width: 100, height: 100)
                .scaleEffect(isPressed ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: isPressed)

            // 主按鈕
            Circle()
                .fill(isPressed ? Color.red : Color.orange)
                .frame(width: 85, height: 85)
                .shadow(
                    color: isPressed ? Color.red.opacity(0.5) : Color.orange.opacity(0.3),
                    radius: isPressed ? 15 : 8,
                    x: 0, y: 4
                )

            // 麥克風圖示
            Image(systemName: isPressed ? "mic.fill" : "mic")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .scaleEffect(isPressed ? 1.1 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isPressed)
        }
        .scaleEffect(isPressed ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        viewModel.startTalking()
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    viewModel.stopTalking()
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
        )
    }

    // MARK: - Helper

    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: TranscriptionViewModel
    @State private var showPurchaseSheet = false
    @State private var authService = AuthService.shared

    // MARK: - 語言偵測模式

    /// 語言偵測模式說明文字
    private var languageDetectionModeDescription: String {
        switch viewModel.sttLanguageDetectionMode {
        case .auto:
            return "自動偵測說話的語言（可能被背景噪音干擾）"
        case .specifySource:
            return "只識別「\(viewModel.sourceLang.shortName)」，忽略其他語言和噪音（重新錄音生效）"
        case .specifyTarget:
            return "只識別「\(viewModel.targetLang.shortName)」，忽略其他語言和噪音（重新錄音生效）"
        }
    }

    // MARK: - VAD 狀態顯示

    /// VAD 狀態文字
    private var vadStateText: String {
        switch viewModel.localVADState {
        case .speaking: return "說話中"
        case .silent: return "靜音中"
        case .paused: return "已暫停"
        }
    }

    /// VAD 狀態顏色
    private var vadStateColor: Color {
        switch viewModel.localVADState {
        case .speaking: return .green
        case .silent: return .orange
        case .paused: return .gray
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ⭐️ 經濟模式開關
                Section {
                    Toggle(isOn: $viewModel.isEconomyMode) {
                        HStack {
                            Image(systemName: "leaf.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text("經濟模式")
                                Text("使用免費的系統語音辨識和合成")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.green)

                    if viewModel.isEconomyMode {
                        // 經濟模式說明
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("STT：Apple 語音辨識（免費）")
                                    .font(.subheadline)
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("TTS：Apple 語音合成（免費）")
                                    .font(.subheadline)
                            }
                        }
                        .padding(.vertical, 4)

                        // ⭐️ 自動語言切換開關
                        Toggle(isOn: $viewModel.isAutoLanguageSwitchEnabled) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text("自動語言切換")
                                    Text("信心度低時自動嘗試另一語言")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.blue)

                        // 信心度閾值滑桿
                        if viewModel.isAutoLanguageSwitchEnabled && !viewModel.isComparisonDisplayMode {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("切換閾值")
                                    Spacer()
                                    Text("\(Int(viewModel.autoSwitchConfidenceThreshold * 100))%")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: $viewModel.autoSwitchConfidenceThreshold,
                                    in: 0.5...0.9,
                                    step: 0.05
                                )
                                .tint(.blue)
                                Text("識別信心度低於此值時，自動切換語言重試")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // ⭐️ 比較顯示模式開關
                        Toggle(isOn: $viewModel.isComparisonDisplayMode) {
                            HStack {
                                Image(systemName: "eye.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text("比較顯示模式")
                                    Text("顯示兩種語言的辨識結果")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.orange)
                    }
                } header: {
                    Text("模式")
                } footer: {
                    if viewModel.isEconomyMode {
                        if viewModel.isComparisonDisplayMode {
                            Text("比較模式：每句話都會同時顯示兩種語言的辨識結果和信心度，方便比較效果")
                        } else if viewModel.isAutoLanguageSwitchEnabled {
                            Text("自動切換：識別結果信心度低於 \(Int(viewModel.autoSwitchConfidenceThreshold * 100))% 時，會自動嘗試另一語言並比較結果")
                        } else {
                            Text("經濟模式不消耗額度，但需要手動切換說話語言")
                        }
                    }
                }

                // ⭐️ TTS 服務商選擇
                Section {
                    Picker(selection: $viewModel.ttsProvider) {
                        ForEach(TTSProvider.allCases) { provider in
                            HStack {
                                Image(systemName: provider.iconName)
                                VStack(alignment: .leading) {
                                    Text(provider.displayName)
                                    Text(provider.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(provider)
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.ttsProvider.iconName)
                                .foregroundStyle(viewModel.ttsProvider.isFree ? .green : .blue)
                            Text("語音合成")
                        }
                    }
                    .pickerStyle(.menu)

                    // 服務商資訊
                    HStack(spacing: 16) {
                        Label {
                            Text(viewModel.ttsProvider.latencyDescription)
                        } icon: {
                            Image(systemName: "timer")
                                .foregroundStyle(.orange)
                        }

                        if viewModel.ttsProvider.isFree {
                            Label {
                                Text("免費")
                            } icon: {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                            }
                        }

                        if !viewModel.ttsProvider.requiresNetwork {
                            Label {
                                Text("離線")
                            } icon: {
                                Image(systemName: "wifi.slash")
                                    .foregroundStyle(.purple)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("TTS 服務商")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if viewModel.ttsProvider == .apple {
                            Text("Apple 內建語音免費且離線可用，但品質不如 Azure 神經語音。")

                            // ⭐️ 檢查當前語言是否支援
                            let sourceLangSupported = AppleTTSService.isLanguageSupported(viewModel.sourceLang.azureLocale)
                            let targetLangSupported = AppleTTSService.isLanguageSupported(viewModel.targetLang.azureLocale)

                            if !sourceLangSupported || !targetLangSupported {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("部分語言不支援，將自動使用 Azure")
                                        .foregroundStyle(.orange)
                                }
                                .padding(.top, 4)
                            }
                        } else {
                            Text("Azure 神經語音品質高，但需要網路且會消耗額度。")
                        }
                    }
                }

                Section("TTS 播放模式") {
                    Picker(selection: $viewModel.ttsPlaybackMode) {
                        ForEach(TTSPlaybackMode.allCases, id: \.self) { mode in
                            HStack {
                                Image(systemName: mode.iconName)
                                Text(mode.displayName)
                            }
                            .tag(mode)
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.ttsPlaybackMode.iconName)
                                .foregroundStyle(ttsPlaybackModeColor(viewModel.ttsPlaybackMode))
                            Text("播放模式")
                        }
                    }

                    // 模式說明（動態顯示具體語言）
                    VStack(alignment: .leading, spacing: 4) {
                        switch viewModel.ttsPlaybackMode {
                        case .all:
                            Text("全部播放：自動播放所有翻譯結果")
                        case .sourceOnly:
                            Text("只播放「\(viewModel.targetLang.shortName)」：當你說\(viewModel.sourceLang.shortName)時，播放\(viewModel.targetLang.shortName)翻譯給對方聽")
                        case .targetOnly:
                            Text("只播放「\(viewModel.sourceLang.shortName)」：當對方說\(viewModel.targetLang.shortName)時，播放\(viewModel.sourceLang.shortName)翻譯給你聽")
                        case .muted:
                            Text("靜音：不播放任何 TTS 語音")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // ⭐️ STT 提供商選擇
                Section("語音轉文字引擎") {
                    Picker(selection: $viewModel.sttProvider) {
                        ForEach(STTProvider.allCases) { provider in
                            HStack {
                                Image(systemName: provider.iconName)
                                VStack(alignment: .leading) {
                                    Text(provider.displayName)
                                    Text("延遲: \(provider.latencyDescription)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(provider)
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.sttProvider.iconName)
                                .foregroundStyle(sttProviderColor(viewModel.sttProvider))
                            Text("STT 引擎")
                        }
                    }

                    // 提供商說明
                    VStack(alignment: .leading, spacing: 4) {
                        switch viewModel.sttProvider {
                        case .chirp3:
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Google Chirp 3：支援 100+ 語言，內建翻譯")
                            }
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundStyle(.orange)
                                Text("延遲約 300-500ms")
                            }
                        case .elevenLabs:
                            HStack {
                                Image(systemName: "bolt.circle.fill")
                                    .foregroundStyle(.blue)
                                Text("ElevenLabs Scribe v2：超低延遲 ~150ms")
                            }
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundStyle(.purple)
                                Text("支援 92 語言，需外部翻譯")
                            }
                        case .apple:
                            HStack {
                                Image(systemName: "apple.logo")
                                    .foregroundStyle(.gray)
                                Text("Apple 內建：免費離線，雙語並行識別")
                            }
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.green)
                                Text("延遲約 100ms，設備端處理")
                            }
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundStyle(.orange)
                                Text("根據信心度自動選擇最佳結果")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // 🚀 音頻加速選項（僅非 Apple STT 顯示）
                    if viewModel.shouldShowSpeedUpOption {
                        Toggle(isOn: $viewModel.isAudioSpeedUpEnabled) {
                            HStack {
                                Image(systemName: viewModel.isAudioSpeedUpEnabled ? "hare.fill" : "hare")
                                    .foregroundStyle(viewModel.isAudioSpeedUpEnabled ? .green : .secondary)
                                VStack(alignment: .leading) {
                                    Text("音頻加速")
                                    Text("1.5x 加速，節省 33% 成本，+300ms 延遲")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.green)
                    }

                    // 🎙️ 本地 Silero VAD 選項（僅非 Apple STT 顯示）
                    if viewModel.shouldShowSpeedUpOption {
                        Toggle(isOn: $viewModel.isLocalVADEnabled) {
                            HStack {
                                Image(systemName: viewModel.isLocalVADEnabled ? "brain.head.profile.fill" : "brain.head.profile")
                                    .foregroundStyle(viewModel.isLocalVADEnabled ? .blue : .secondary)
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text("智慧語音偵測")
                                        if viewModel.isLocalVADEnabled {
                                            Text(vadStateText)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(vadStateColor.opacity(0.2))
                                                .foregroundStyle(vadStateColor)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text("Silero ML 語音偵測，靜音後暫停發送節省費用")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.blue)

                        // ⭐️ Silero VAD 閾值滑桿
                        if viewModel.isLocalVADEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("語音偵測靈敏度")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.0f%%", viewModel.localVADSpeechThreshold * 100))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }

                                HStack {
                                    Image(systemName: "ear")
                                        .foregroundStyle(.green)
                                        .font(.caption)

                                    Slider(value: $viewModel.localVADSpeechThreshold, in: 0.1...0.9, step: 0.05)

                                    Image(systemName: "ear.trianglebadge.exclamationmark")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                }

                                Text("越低越敏感（容易誤觸發），越高越嚴格（可能漏偵測）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // ⭐️ 翻譯模型選擇
                Section("翻譯模型") {
                    Picker(selection: $viewModel.translationProvider) {
                        ForEach(TranslationProvider.allCases) { provider in
                            HStack {
                                Image(systemName: provider.iconName)
                                VStack(alignment: .leading) {
                                    Text(provider.displayName)
                                    HStack(spacing: 8) {
                                        Text(provider.latencyDescription)
                                        Text("•")
                                        Text(provider.priceLevel)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .tag(provider)
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.translationProvider.iconName)
                                .foregroundStyle(translationProviderColor(viewModel.translationProvider))
                            Text("翻譯引擎")
                        }
                    }

                    // 模型說明
                    VStack(alignment: .leading, spacing: 4) {
                        switch viewModel.translationProvider {
                        case .gemini:
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.purple)
                                Text("Gemini 3 Flash：平衡型，預設推薦")
                            }
                            HStack {
                                Image(systemName: "dollarsign.circle")
                                    .foregroundStyle(.orange)
                                Text("$0.50/M 輸入 • $3.00/M 輸出")
                            }
                        case .geminiFlashLite:
                            HStack {
                                Image(systemName: "sparkle")
                                    .foregroundStyle(.mint)
                                Text("Gemini 3.1 Flash Lite：超值最便宜")
                            }
                            HStack {
                                Image(systemName: "dollarsign.circle")
                                    .foregroundStyle(.green)
                                Text("$0.075/M 輸入 • $0.30/M 輸出")
                            }
                        case .grok:
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text("Grok 4.1 Fast：高品質翻譯")
                            }
                            HStack {
                                Image(systemName: "dollarsign.circle")
                                    .foregroundStyle(.green)
                                Text("$0.20/M 輸入 • $0.50/M 輸出")
                            }
                        case .cerebras:
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.blue)
                                Text("Cerebras：極速回應 ~380ms")
                            }
                            HStack {
                                Image(systemName: "dollarsign.circle")
                                    .foregroundStyle(.green)
                                Text("$0.85/M 輸入 • $1.20/M 輸出")
                            }
                        case .qwen:
                            HStack {
                                Image(systemName: "brain.head.profile")
                                    .foregroundStyle(.cyan)
                                Text("Qwen 3 235B：高品質+快速 ~460ms")
                            }
                            HStack {
                                Image(systemName: "dollarsign.circle")
                                    .foregroundStyle(.green)
                                Text("$0.60/M 輸入 • $1.20/M 輸出")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // ⭐️ 翻譯風格設定
                Section("翻譯風格") {
                    Picker(selection: $viewModel.translationStyle) {
                        ForEach(TranslationStyle.allCases) { style in
                            HStack {
                                Image(systemName: style.iconName)
                                VStack(alignment: .leading) {
                                    Text(style.displayName)
                                    Text(style.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(style)
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.translationStyle.iconName)
                                .foregroundStyle(.purple)
                            Text("風格")
                        }
                    }

                    // 自訂風格輸入框（僅在選擇「自訂」時顯示）
                    if viewModel.translationStyle == .custom {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("風格描述")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("例如：用東北話翻譯、像海盜一樣說話...", text: $viewModel.customStylePrompt, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                                .font(.subheadline)
                        }
                    }

                    // 當前風格說明
                    if viewModel.translationStyle != .neutral {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            if viewModel.translationStyle == .custom {
                                Text(viewModel.customStylePrompt.isEmpty ? "請輸入風格描述" : "使用自訂風格")
                            } else {
                                Text("翻譯將使用「\(viewModel.translationStyle.displayName)」風格")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                // ⭐️ ElevenLabs 專用設定
                if viewModel.sttProvider == .elevenLabs {

                    // ⭐️ 語言偵測模式
                    Section("語言偵測模式") {
                        Picker("偵測模式", selection: $viewModel.sttLanguageDetectionMode) {
                            Text("自動").tag(STTLanguageDetectionMode.auto)
                            Text("來源語言").tag(STTLanguageDetectionMode.specifySource)
                            Text("目標語言").tag(STTLanguageDetectionMode.specifyTarget)
                        }
                        .pickerStyle(.segmented)

                        // 顯示當前模式的說明
                        Text(languageDetectionModeDescription)
                            .font(.caption2)
                            .foregroundStyle(viewModel.sttLanguageDetectionMode == .auto ? Color.secondary : Color.blue)
                            .padding(.vertical, 2)
                    }

                    // 麥克風增益、VAD 靈敏度、伺服器設定已隱藏（使用程式碼預設值）
                }

                Section("鎖屏設定") {
                    Toggle(isOn: $viewModel.isLockScreenAutoEnd) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("鎖定螢幕自動結束通話")
                                .font(.subheadline)
                            Text("關閉後鎖屏持續錄音，可從鎖屏控制中斷")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("關於") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("2.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("轉錄引擎")
                        Spacer()
                        Text(viewModel.sttProvider.displayName)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("翻譯引擎")
                        Spacer()
                        Text("Cerebras gpt-oss-120b")
                            .foregroundStyle(.secondary)
                    }
                }

                // ⭐️ 帳號資訊區塊
                Section("帳號") {
                    if let user = AuthService.shared.currentUser {
                        // 用戶資訊
                        HStack(spacing: 12) {
                            // 頭像
                            if let photoURL = user.photoURL,
                               let url = URL(string: photoURL) {
                                AsyncImage(url: url) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.gray)
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.gray)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName ?? "用戶")
                                    .font(.headline)
                                Text(user.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        // 額度顯示（含購買按鈕）
                        HStack {
                            Text("超值額度")
                            Spacer()
                            Text("\(formatCredits(user.slowCredits))")
                                .foregroundStyle(.green)
                                .fontWeight(.semibold)

                            // 購買按鈕
                            Button {
                                showPurchaseSheet = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                    Image(systemName: "wallet.bifold.fill")
                                }
                                .font(.title3)
                                .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 登出按鈕
                    Button(role: .destructive) {
                        try? AuthService.shared.signOut()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("登出")
                        }
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPurchaseSheet) {
                PurchaseView()
            }
            .onAppear {
                // ⭐️ 設定頁面出現時啟用音量監測
                viewModel.isVolumeMonitoringEnabled = true
            }
            .onDisappear {
                // ⭐️ 設定頁面消失時禁用音量監測，避免不必要的 UI 更新
                viewModel.isVolumeMonitoringEnabled = false
            }
        }
    }

    /// 格式化額度數字（添加千位分隔符）
    private func formatCredits(_ credits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: credits)) ?? "\(credits)"
    }

    /// VAD 靈敏度標籤
    private func vadSensitivityLabel(_ threshold: Float) -> String {
        if threshold < 0.25 {
            return "非常敏感"
        } else if threshold < 0.4 {
            return "敏感"
        } else if threshold < 0.55 {
            return "標準"
        } else if threshold < 0.7 {
            return "嚴格"
        } else {
            return "非常嚴格"
        }
    }

    /// VAD 靈敏度顏色
    private func vadSensitivityColor(_ threshold: Float) -> Color {
        if threshold < 0.25 {
            return .red
        } else if threshold < 0.4 {
            return .orange
        } else if threshold < 0.55 {
            return .blue
        } else if threshold < 0.7 {
            return .purple
        } else {
            return .gray
        }
    }

    /// 根據 TTS 播放模式返回對應顏色
    private func ttsPlaybackModeColor(_ mode: TTSPlaybackMode) -> Color {
        switch mode {
        case .all:
            return .green
        case .sourceOnly:
            return .blue
        case .targetOnly:
            return .orange
        case .muted:
            return .gray
        }
    }

    /// 根據 STT 提供商返回對應顏色
    private func sttProviderColor(_ provider: STTProvider) -> Color {
        switch provider {
        case .chirp3:
            return .green
        case .elevenLabs:
            return .blue
        case .apple:
            return .gray
        }
    }

    /// 根據翻譯模型返回對應顏色
    private func translationProviderColor(_ provider: TranslationProvider) -> Color {
        switch provider {
        case .gemini:
            return .purple
        case .geminiFlashLite:
            return .mint
        case .grok:
            return .yellow
        case .cerebras:
            return .blue
        case .qwen:
            return .cyan
        }
    }

    /// 根據麥克風增益返回對應顏色
    private func micGainColor(_ gain: Float) -> Color {
        if gain <= 1.0 {
            return .secondary
        } else if gain < 2.0 {
            return .blue
        } else if gain < 3.0 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Credits Toolbar View

/// 額度顯示工具欄視圖（含消耗明細彈窗）
struct CreditsToolbarView: View {
    @Binding var showSettings: Bool
    var isRecording: Bool = false  // ⭐️ 通話中隱藏購買按鈕
    @State private var showUsageDetail = false
    @State private var showPurchaseSheet = false

    private var authService: AuthService { AuthService.shared }
    // ⭐️ 使用 @Bindable 監聽 BillingService 變化（斷開連結後也能顯示消耗）
    @Bindable private var billingService = BillingService.shared

    /// ⭐️ 格式化額度（完整數字，千位分隔符）
    private func formatUsageCredits(_ credits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: credits)) ?? "\(credits)"
    }

    var body: some View {
        HStack(spacing: 12) {
            // 剩餘額度
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                Text("\(formatUsageCredits(authService.currentUser?.slowCredits ?? 0))")
                    .font(.system(size: 15, weight: .semibold))
            }
            .fixedSize()  // ⭐️ 防止被壓縮

            // 購買額度按鈕（通話中隱藏）
            if !isRecording {
                Button {
                    showPurchaseSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bag.circle.fill")
                            .font(.system(size: 14))
                        Text("購買額度")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [.orange, .red.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showPurchaseSheet) {
                    PurchaseView()
                }
            }

            // ⭐️ 本次消耗額度（只在通話中顯示）
            if isRecording && billingService.sessionTotalCreditsUsed > 0 {
                Button {
                    showUsageDetail = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("-\(formatUsageCredits(billingService.sessionTotalCreditsUsed))")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()  // ⭐️ 防止被壓縮折疊
                .layoutPriority(1)  // ⭐️ 通話中優先顯示消耗額度
                .popover(isPresented: $showUsageDetail, arrowEdge: .top) {
                    UsageDetailPopover(billingService: billingService)
                }
            }
        }
    }
}

// MARK: - Usage Detail Popover

/// 額度消耗明細彈窗
struct UsageDetailPopover: View {
    let billingService: BillingService

    private var totalCredits: Int { billingService.sessionTotalCreditsUsed }
    private var sttCredits: Int { billingService.sessionSTTCreditsUsed }
    private var llmCredits: Int { billingService.sessionLLMCreditsUsed }
    private var ttsCredits: Int { billingService.sessionTTSCreditsUsed }

    /// 計算百分比
    private func percentage(of value: Int) -> Double {
        guard totalCredits > 0 else { return 0 }
        return Double(value) / Double(totalCredits) * 100
    }

    /// 格式化秒數為 mm:ss
    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        } else {
            return String(format: "%.1f 秒", seconds)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 標題
            HStack {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("本次消耗明細")
                    .font(.headline)
                Spacer()
                Text("-\(totalCredits)")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
            }

            Divider()

            // 消耗組成圖表
            VStack(spacing: 16) {
                // STT 語音識別
                UsageItemView(
                    icon: "waveform",
                    iconColor: .blue,
                    title: "語音識別 (STT)",
                    credits: sttCredits,
                    percentage: percentage(of: sttCredits),
                    details: [
                        ("時長", formatDuration(billingService.sessionSTTSeconds))
                    ]
                )

                // LLM 翻譯
                UsageItemView(
                    icon: "brain",
                    iconColor: .purple,
                    title: "AI 翻譯 (LLM)",
                    credits: llmCredits,
                    percentage: percentage(of: llmCredits),
                    details: [
                        ("調用", "\(billingService.sessionLLMCallCount) 次"),
                        ("Input", "\(billingService.sessionLLMInputTokens)"),
                        ("Output", "\(billingService.sessionLLMOutputTokens)")
                    ]
                )

                // TTS 語音合成
                UsageItemView(
                    icon: "speaker.wave.2.fill",
                    iconColor: .green,
                    title: "語音合成 (TTS)",
                    credits: ttsCredits,
                    percentage: percentage(of: ttsCredits),
                    details: [
                        ("字數", "\(billingService.sessionTTSChars) 字")
                    ]
                )
            }

            Divider()

            // 底部說明
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("從 App 啟動起累計")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Usage Item View (Enhanced)

/// 單個消耗項目視圖（增強版，支援多行詳細資訊）
struct UsageItemView: View {
    let icon: String
    let iconColor: Color
    let title: String
    let credits: Int
    let percentage: Double
    let details: [(String, String)]  // (標籤, 值)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 標題行
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                Text(title)
                    .font(.subheadline.bold())

                Spacer()

                Text("-\(credits)")
                    .font(.subheadline.bold())
                    .foregroundStyle(credits > 0 ? iconColor : .secondary)
            }

            // 進度條
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)

                    // 進度
                    Capsule()
                        .fill(iconColor.opacity(0.8))
                        .frame(width: geometry.size.width * CGFloat(percentage / 100), height: 6)
                }
            }
            .frame(height: 6)

            // 詳細資訊（多欄顯示）
            HStack(spacing: 16) {
                ForEach(details, id: \.0) { detail in
                    HStack(spacing: 4) {
                        Text(detail.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(detail.1)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                    }
                }

                Spacer()

                Text(String(format: "%.1f%%", percentage))
                    .font(.caption.bold())
                    .foregroundStyle(iconColor)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Usage Item Row

/// 單個消耗項目行
struct UsageItemRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let credits: Int
    let percentage: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 標題行
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                Text(title)
                    .font(.subheadline)

                Spacer()

                Text("-\(credits)")
                    .font(.subheadline.bold())
                    .foregroundStyle(credits > 0 ? .primary : .secondary)
            }

            // 進度條
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)

                    // 進度
                    Capsule()
                        .fill(iconColor)
                        .frame(width: geometry.size.width * CGFloat(percentage / 100), height: 8)
                }
            }
            .frame(height: 8)

            // 詳細資訊
            HStack {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(String(format: "%.1f%%", percentage))
                    .font(.caption.bold())
                    .foregroundStyle(iconColor)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - VAD 音量條視圖

/// 顯示即時麥克風音量和 VAD 閾值的視覺化組件
struct VADVolumeMeter: View {
    let currentVolume: Float
    let vadThreshold: Float

    /// 音量條顏色（根據是否超過閾值變化）
    private var volumeBarColor: Color {
        if currentVolume >= vadThreshold {
            return .green  // 超過閾值：綠色（會觸發 VAD）
        } else {
            return .gray   // 低於閾值：灰色（不會觸發）
        }
    }

    /// 閾值線顏色
    private var thresholdLineColor: Color {
        currentVolume >= vadThreshold ? .green : .orange
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))

                // 音量條
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [volumeBarColor.opacity(0.7), volumeBarColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * CGFloat(currentVolume)))
                    .animation(.easeOut(duration: 0.1), value: currentVolume)

                // VAD 閾值線（虛線）
                Rectangle()
                    .fill(thresholdLineColor)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * CGFloat(vadThreshold) - 1)

                // 閾值標籤
                Text("閾值")
                    .font(.system(size: 8))
                    .foregroundStyle(thresholdLineColor)
                    .offset(x: geometry.size.width * CGFloat(vadThreshold) - 12, y: -14)
            }
        }
        .frame(height: 24)
    }
}

// MARK: - 麥克風增益預設按鈕

struct MicGainPresetButton: View {
    let label: String
    let value: Float
    @Binding var current: Float

    private var isSelected: Bool {
        abs(current - value) < 0.05
    }

    var body: some View {
        Button {
            current = value
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .cornerRadius(6)
        }
    }
}

#Preview {
    ContentView()
}
