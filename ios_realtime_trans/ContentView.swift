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
    @State private var viewModel = TranscriptionViewModel()
    @State private var showSettings = false

    /// ⭐️ 用戶是否正在查看舊訊息（手動往上滾動）
    @State private var isUserScrolledUp = false

    /// ⭐️ 是否已經預取過 token（防止重複預取）
    @State private var hasPreFetchedToken = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 對話區域
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // 最終結果（從舊到新，從上到下）
                            ForEach(viewModel.transcripts) { transcript in
                                ConversationBubbleView(
                                    transcript: transcript,
                                    sourceLang: viewModel.sourceLang,
                                    targetLang: viewModel.targetLang,
                                    onPlayTTS: { text, langCode in
                                        // ⭐️ 使用統一的 AudioManager 播放（啟用 AEC）
                                        viewModel.enqueueTTS(text: text, languageCode: langCode)
                                    }
                                )
                                .id(transcript.id)
                            }

                            // Interim 結果（最新的，在最下面）
                            if let interim = viewModel.interimTranscript {
                                ConversationBubbleView(
                                    transcript: interim,
                                    sourceLang: viewModel.sourceLang,
                                    targetLang: viewModel.targetLang,
                                    onPlayTTS: { text, langCode in
                                        viewModel.enqueueTTS(text: text, languageCode: langCode)
                                    }
                                )
                                .id("interim")
                            }
                            // ⭐️ 底部錨點（用於檢測滾動位置）
                            Color.clear
                                .frame(height: 1)
                                .id("bottomAnchor")
                        }
                        .padding()
                        // ⭐️ 使用 GeometryReader 追蹤內容位置
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
                    // ⭐️ 檢測手勢：用戶向下滑動表示在查看舊訊息
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.height > 30 {
                                    // 用戶向下滑動（往上看舊訊息）
                                    if !isUserScrolledUp {
                                        isUserScrolledUp = true
                                        print("📜 [Scroll] 用戶開始查看舊訊息")
                                    }
                                }
                            }
                    )
                    .onChange(of: viewModel.transcripts.count) { _, _ in
                        // ⭐️ 只有在用戶沒有往上滾動時才自動滾動
                        guard !isUserScrolledUp else {
                            print("📜 [Scroll] 用戶正在查看舊訊息，不自動滾動")
                            return
                        }
                        if let lastId = viewModel.transcripts.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.interimTranscript) { _, _ in
                        // ⭐️ 只有在用戶沒有往上滾動時才自動滾動
                        guard !isUserScrolledUp else { return }
                        withAnimation {
                            proxy.scrollTo("interim", anchor: .bottom)
                        }
                    }
                    // ⭐️ 「返回最新」指示條（細長、低調、置中）
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
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("新訊息")
                                        .font(.system(size: 11, weight: .medium))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.5))
                                )
                            }
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .animation(.easeOut(duration: 0.2), value: isUserScrolledUp)
                        }
                    }
                }

                // 底部控制區（重構版 - 參考開講AI設計）
                BottomControlBar(viewModel: viewModel)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("即時翻譯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.clearTranscripts()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.isRecording || viewModel.transcripts.isEmpty)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            // ⭐️ App 出現時預取 ElevenLabs token（只執行一次）
            .onAppear {
                if !hasPreFetchedToken {
                    hasPreFetchedToken = true
                    viewModel.prefetchElevenLabsToken()
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

    /// 隱藏狀態
    @State private var isHidden: Bool = false
    /// 複製反饋狀態
    @State private var showCopiedFeedback: Bool = false

    /// 判斷是否為來源語言（用戶說的話）
    /// 根據 Chirp3 返回的語言代碼與用戶設定的來源語言比較
    private var isSourceLanguage: Bool {
        guard let detectedLang = transcript.language else { return true }
        let detectedBase = detectedLang.split(separator: "-").first.map(String.init) ?? detectedLang
        return detectedBase == sourceLang.rawValue
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

    /// 是否顯示控制按鈕（播放 + 隱藏）
    private var showControlButtons: Bool {
        transcript.isFinal && transcript.translation != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左邊留空（來源語言在右側）
            if isSourceLanguage {
                Spacer(minLength: 60)
            }

            // 控制按鈕（左側，僅來源語言/右邊氣泡顯示）
            if isSourceLanguage && showControlButtons {
                controlButtons
            }

            // 對話氣泡內容
            if !isHidden {
                bubbleContent
            } else {
                // 隱藏時顯示摺疊指示
                collapsedIndicator
            }

            // 控制按鈕（右側，僅目標語言/左邊氣泡顯示）
            if !isSourceLanguage && showControlButtons {
                controlButtons
            }

            // 右邊留空（目標語言在左側）
            if !isSourceLanguage {
                Spacer(minLength: 60)
            }
        }
        // ⭐️ 不再使用透明度區分 interim/final，讓所有氣泡看起來一樣
    }

    /// 氣泡內容
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 原文（⭐️ 不再區分 interim/final 的顏色）
            Text(transcript.text)
                .font(.body)
                .foregroundStyle(textColor)

            // 翻譯（較小字體）
            if let translation = transcript.translation {
                Text(translation)
                    .font(.subheadline)
                    .foregroundStyle(secondaryTextColor)
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
        .background(bubbleColor)
        .cornerRadius(18)
    }

    /// 摺疊後的指示器
    private var collapsedIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "ellipsis")
                .font(.caption)
            Text("已隱藏")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    /// 控制按鈕組（複製 + 播放 + 隱藏/顯示）
    private var controlButtons: some View {
        VStack(spacing: 6) {
            // 複製按鈕
            Button {
                copyAllContent()
            } label: {
                Image(systemName: showCopiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.title3)
                    .foregroundStyle(showCopiedFeedback ? .green : .gray)
            }

            // 播放按鈕
            Button {
                // ⭐️ 直接使用 Language enum 的 azureLocale 屬性
                onPlayTTS?(transcript.translation!, targetLang.azureLocale)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }

            // 隱藏/顯示按鈕
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHidden.toggle()
                }
            } label: {
                Image(systemName: isHidden ? "eye.fill" : "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isHidden ? .green : .gray)
            }
        }
    }

    /// 複製原文和翻譯到剪貼簿
    private func copyAllContent() {
        var content = transcript.text
        if let translation = transcript.translation {
            content += "\n\n" + translation
        }

        UIPasteboard.general.string = content

        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedFeedback = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedFeedback = false
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

// MARK: - Bottom Control Bar (底部控制區 - 仿開講AI設計)

struct BottomControlBar: View {
    @Bindable var viewModel: TranscriptionViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 16) {
                // === 第一行：語言選擇器 + 模式切換 ===
                LanguageSelectorRow(viewModel: viewModel)

                // === 第二行：喇叭 + 麥克風 並排居中（僅錄音時顯示）===
                if viewModel.isRecording {
                    DualIconControlRow(viewModel: viewModel)
                }

                // === 第三行：通話按鈕置中 ===
                CenteredCallButton(viewModel: viewModel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
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

// MARK: - 通話按鈕置中

struct CenteredCallButton: View {
    @Bindable var viewModel: TranscriptionViewModel

    // 滑動狀態
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    // 尺寸常數
    private let trackWidth: CGFloat = 280
    private let trackHeight: CGFloat = 70
    private let thumbSize: CGFloat = 60
    private let threshold: CGFloat = 0.6  // 滑動超過 60% 觸發

    // 計算滑動範圍
    private var maxOffset: CGFloat {
        trackWidth - thumbSize - 10
    }

    // 背景顏色
    private var trackColor: Color {
        viewModel.isRecording ? Color.red.opacity(0.15) : Color.green.opacity(0.15)
    }

    // 按鈕顏色
    private var thumbGradient: LinearGradient {
        if viewModel.isRecording {
            return LinearGradient(
                colors: [Color.pink, Color.red],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.green, Color.mint],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var body: some View {
        HStack {
            Spacer()

            ZStack {
                // 背景軌道
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(trackColor)
                    .frame(width: trackWidth, height: trackHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )

                // 左邊圖標（結束通話）
                HStack {
                    Image(systemName: "phone.down.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(viewModel.isRecording ? 0.8 : 0.3))
                        .padding(.leading, 18)
                    Spacer()
                }
                .frame(width: trackWidth)

                // 右邊圖標（開始通話）
                HStack {
                    Spacer()
                    Image(systemName: "phone.fill")
                        .font(.title3)
                        .foregroundStyle(.green.opacity(viewModel.isRecording ? 0.3 : 0.8))
                        .padding(.trailing, 18)
                }
                .frame(width: trackWidth)

                // 中間提示文字
                Text(viewModel.isRecording ? "← 滑動結束" : "滑動開始 →")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                // 可滑動的按鈕
                Circle()
                    .fill(thumbGradient)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: viewModel.isRecording ? .red.opacity(0.4) : .green.opacity(0.4), radius: 8, x: 0, y: 4)
                    .overlay(
                        Image(systemName: viewModel.isRecording ? "waveform" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    )
                    .scaleEffect(isDragging ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isDragging)
                    .offset(x: thumbPosition + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                if viewModel.isRecording {
                                    // 通話中：只能往左滑
                                    dragOffset = min(0, max(-maxOffset, value.translation.width))
                                } else {
                                    // 未通話：只能往右滑
                                    dragOffset = max(0, min(maxOffset, value.translation.width))
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                                let progress = abs(dragOffset) / maxOffset

                                if progress > threshold {
                                    // 觸覺反饋
                                    let generator = UIImpactFeedbackGenerator(style: .medium)
                                    generator.impactOccurred()

                                    // 執行操作
                                    Task {
                                        await viewModel.toggleRecording()
                                    }
                                }

                                // 彈回原位
                                withAnimation(.spring(response: 0.3)) {
                                    dragOffset = 0
                                }
                            }
                    )
            }
            .frame(width: trackWidth, height: trackHeight)

            Spacer()
        }
    }

    // 計算按鈕初始位置
    private var thumbPosition: CGFloat {
        let halfTrack = (trackWidth - thumbSize) / 2 - 5
        return viewModel.isRecording ? halfTrack : -halfTrack
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
    @State private var volumeValue: Float = 0.5

    var body: some View {
        NavigationStack {
            Form {
                // ⭐️ 音量設定區塊
                Section("TTS 音量") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "speaker.wave.1")
                                .foregroundStyle(.secondary)

                            // ⭐️ 直接綁定到 viewModel，滑塊和本地狀態雙向同步
                            Slider(value: $volumeValue, in: 0...1, step: 0.05)
                                .onChange(of: volumeValue) { _, newValue in
                                    viewModel.ttsVolume = newValue
                                }

                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("增益: +\(Int(volumeValue * 36)) dB（3頻段EQ）")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(Int(volumeValue * 100))%")
                                .font(.headline)
                                .foregroundStyle(volumeColor)
                        }
                    }
                    .padding(.vertical, 4)

                    // 快捷按鈕
                    HStack(spacing: 12) {
                        VolumePresetButton(label: "小", value: 0.25, current: $volumeValue) {
                            viewModel.ttsVolume = 0.25
                        }
                        VolumePresetButton(label: "中", value: 0.5, current: $volumeValue) {
                            viewModel.ttsVolume = 0.5
                        }
                        VolumePresetButton(label: "大", value: 0.75, current: $volumeValue) {
                            viewModel.ttsVolume = 0.75
                        }
                        VolumePresetButton(label: "最大", value: 1.0, current: $volumeValue) {
                            viewModel.ttsVolume = 1.0
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
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // ⭐️ VAD 靈敏度設定（ElevenLabs 專用）
                if viewModel.sttProvider == .elevenLabs {
                    Section("語音偵測靈敏度（VAD）") {
                        // 即時音量顯示
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("麥克風音量")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(viewModel.currentMicVolume * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            // 音量條
                            VADVolumeMeter(
                                currentVolume: viewModel.currentMicVolume,
                                vadThreshold: viewModel.vadThreshold
                            )
                        }
                        .padding(.vertical, 4)

                        // VAD 閾值滑桿
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("VAD 閾值")
                                    .font(.subheadline)
                                Spacer()
                                Text(vadSensitivityLabel(viewModel.vadThreshold))
                                    .font(.caption)
                                    .foregroundStyle(vadSensitivityColor(viewModel.vadThreshold))
                                    .fontWeight(.medium)
                            }

                            HStack {
                                Image(systemName: "ear")
                                    .foregroundStyle(.green)
                                    .font(.caption)

                                Slider(value: $viewModel.vadThreshold, in: 0.1...0.8, step: 0.05)

                                Image(systemName: "ear.trianglebadge.exclamationmark")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }

                            Text("音量超過閾值線（虛線）才會觸發語音識別")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)

                        // 最小語音長度
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("最小語音長度")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(viewModel.minSpeechDurationMs) ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            Picker("", selection: $viewModel.minSpeechDurationMs) {
                                Text("100 ms（敏感）").tag(100)
                                Text("200 ms").tag(200)
                                Text("300 ms（建議）").tag(300)
                                Text("500 ms（嚴格）").tag(500)
                            }
                            .pickerStyle(.segmented)

                            Text("語音必須持續超過此時間才會被識別，可過濾短噪音")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("伺服器設定") {
                    TextField("伺服器 URL", text: $viewModel.serverURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)

                    Text("例如：your-server.run.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .onAppear {
                volumeValue = viewModel.ttsVolume
                // ⭐️ 設定頁面出現時啟用音量監測
                viewModel.isVolumeMonitoringEnabled = true
            }
            .onDisappear {
                // ⭐️ 設定頁面消失時禁用音量監測，避免不必要的 UI 更新
                viewModel.isVolumeMonitoringEnabled = false
            }
        }
    }

    private var volumeColor: Color {
        if volumeValue < 0.3 {
            return .green
        } else if volumeValue < 0.7 {
            return .orange
        } else {
            return .red
        }
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
        }
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

// MARK: - 音量預設按鈕

struct VolumePresetButton: View {
    let label: String
    let value: Float
    @Binding var current: Float
    let action: () -> Void

    private var isSelected: Bool {
        abs(current - value) < 0.05
    }

    var body: some View {
        Button {
            current = value
            action()
        } label: {
            Text(label)
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .cornerRadius(8)
        }
    }
}

#Preview {
    ContentView()
}
