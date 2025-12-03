//
//  ContentView.swift
//  ios_realtime_trans
//
//  Chirp3 即時語音轉錄 iOS 版本
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = TranscriptionViewModel()
    @State private var showSettings = false

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
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.transcripts.count) { _, _ in
                        // 自動滾動到最新訊息
                        if let lastId = viewModel.transcripts.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.interimTranscript) { _, _ in
                        // 滾動到 interim
                        withAnimation {
                            proxy.scrollTo("interim", anchor: .bottom)
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
        .opacity(transcript.isFinal ? 1.0 : 0.8)
    }

    /// 氣泡內容
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 原文
            Text(transcript.text)
                .font(.body)
                .foregroundStyle(transcript.isFinal ? textColor : textColor.opacity(0.7))

            // 翻譯（較小字體）
            if let translation = transcript.translation {
                Text(translation)
                    .font(.subheadline)
                    .foregroundStyle(secondaryTextColor)
            }

            // 元數據行
            HStack(spacing: 6) {
                if let language = transcript.language {
                    Text(languageDisplayName(language))
                        .font(.caption2)
                }

                if transcript.isFinal && transcript.confidence > 0 {
                    Text("·")
                    Text("\(Int(transcript.confidence * 100))%")
                        .font(.caption2)
                }

                if !transcript.isFinal {
                    TypingIndicator()
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

    /// 控制按鈕組（播放 + 隱藏/顯示）
    private var controlButtons: some View {
        VStack(spacing: 6) {
            // 播放按鈕
            Button {
                let langCode = mapLanguageCode(targetLang.rawValue)
                onPlayTTS?(transcript.translation!, langCode)
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

    private func mapLanguageCode(_ lang: String) -> String {
        // 映射簡單語言代碼到 Azure TTS 完整格式
        let mapping: [String: String] = [
            "zh": "zh-TW",
            "en": "en-US",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "es": "es-ES",
            "fr": "fr-FR",
            "de": "de-DE",
            "it": "it-IT",
            "pt": "pt-BR",
            "ru": "ru-RU",
            "ar": "ar-SA",
            "hi": "hi-IN",
            "th": "th-TH",
            "vi": "vi-VN"
        ]
        return mapping[lang] ?? "zh-TW"
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

    var body: some View {
        HStack(spacing: 12) {
            // 語言選擇器
            HStack(spacing: 8) {
                // 來源語言
                Menu {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Button {
                            viewModel.sourceLang = lang
                        } label: {
                            HStack {
                                Text(lang.flag)
                                Text(lang.displayName)
                                if viewModel.sourceLang == lang {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
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

                // 目標語言
                Menu {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Button {
                            viewModel.targetLang = lang
                        } label: {
                            HStack {
                                Text(lang.flag)
                                Text(lang.displayName)
                                if viewModel.targetLang == lang {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
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
            // 切換到下一個 TTS 播放模式
            viewModel.ttsPlaybackMode = viewModel.ttsPlaybackMode.next()
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
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

    var body: some View {
        HStack {
            Spacer()

            Button {
                Task {
                    await viewModel.toggleRecording()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.isRecording ? "phone.down.fill" : "phone.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text(viewModel.isRecording ? "結束通話" : "開始通話")
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(viewModel.isRecording ? Color.red : Color.blue)
                .cornerRadius(28)
                .shadow(color: (viewModel.isRecording ? Color.red : Color.blue).opacity(0.4), radius: 8, x: 0, y: 4)
            }

            Spacer()
        }
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
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("轉錄引擎")
                        Spacer()
                        Text("Google Chirp 3")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("翻譯引擎")
                        Spacer()
                        Text("Cerebras llama-3.3-70b")
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
