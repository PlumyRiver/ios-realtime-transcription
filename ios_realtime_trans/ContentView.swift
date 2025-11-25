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
                                ConversationBubbleView(transcript: transcript, targetLang: viewModel.targetLang)
                                    .id(transcript.id)
                            }

                            // Interim 結果（最新的，在最下面）
                            if let interim = viewModel.interimTranscript {
                                ConversationBubbleView(transcript: interim, targetLang: viewModel.targetLang)
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

                // 底部控制列
                VStack(spacing: 0) {
                    Divider()

                    HStack(spacing: 16) {
                        // 語言選擇（精簡版）
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(Language.allCases, id: \.self) { lang in
                                    Button(lang.displayName) {
                                        viewModel.sourceLang = lang
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(viewModel.sourceLang.flag)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .disabled(viewModel.isRecording)

                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Menu {
                                ForEach(Language.allCases, id: \.self) { lang in
                                    Button(lang.displayName) {
                                        viewModel.targetLang = lang
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(viewModel.targetLang.flag)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .disabled(viewModel.isRecording)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(20)

                        Spacer()

                        // 擴音按鈕
                        Button {
                            viewModel.toggleSpeakerMode()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: viewModel.isSpeakerMode ? "speaker.wave.3.fill" : "speaker.wave.2")
                                    .font(.system(size: 20))
                                Text("擴音")
                                    .font(.caption2)
                            }
                            .foregroundStyle(viewModel.isSpeakerMode ? Color.blue : Color.secondary)
                            .frame(width: 60, height: 60)
                            .background(viewModel.isSpeakerMode ? Color.blue.opacity(0.1) : Color(.systemGray6))
                            .cornerRadius(12)
                        }
                        .disabled(!viewModel.isRecording)
                        .opacity(viewModel.isRecording ? 1.0 : 0.5)

                        // 通話按鈕
                        Button {
                            Task {
                                await viewModel.toggleRecording()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.isRecording ? "phone.down.fill" : "phone.fill")
                                Text(viewModel.isRecording ? "結束通話" : "開始通話")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(viewModel.isRecording ? Color.red : Color.blue)
                            .cornerRadius(25)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                }
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
                SettingsView(serverURL: $viewModel.serverURL)
            }
        }
    }
}

// MARK: - Conversation Bubble View

struct ConversationBubbleView: View {
    let transcript: TranscriptMessage
    let targetLang: Language
    @State private var ttsService = AzureTTSService()
    @State private var isPlaying = false
    @State private var isSynthesizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 轉錄文字區域
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript.text)
                        .font(.body)
                        .foregroundStyle(transcript.isFinal ? .primary : .secondary)

                    // 元數據行
                    HStack(spacing: 8) {
                        if let language = transcript.language {
                            Text(languageDisplayName(language))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if transcript.isFinal && transcript.confidence > 0 {
                            Text("\(Int(transcript.confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if !transcript.isFinal {
                            HStack(spacing: 2) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 3, height: 3)
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 3, height: 3)
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 3, height: 3)
                            }
                        }
                    }
                }

                // TTS 播放按鈕（只在 final 結果且有翻譯時顯示）
                if transcript.isFinal && transcript.translation != nil {
                    Button {
                        Task {
                            // 播放翻譯內容（使用目標語言）
                            await playTTS(text: transcript.translation!, language: targetLang.rawValue)
                        }
                    } label: {
                        if isSynthesizing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                        }
                    }
                    .disabled(isSynthesizing)
                }
            }
            .padding()

            // 分隔線（只在有翻譯時顯示）
            if let translation = transcript.translation {
                Divider()
                    .padding(.horizontal)

                // 翻譯文字區域
                Text(translation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .opacity(transcript.isFinal ? 1.0 : 0.7)
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

    private func playTTS(text: String, language: String) async {
        if isPlaying {
            // 停止播放
            ttsService.stop()
            isPlaying = false
            return
        }

        // ⭐️ 立即更新 UI 狀態（不阻塞用戶操作）
        await MainActor.run {
            isSynthesizing = true
        }

        do {
            // 映射語言代碼到 Azure TTS 格式
            let langCode = mapLanguageCode(language)

            print("🔊 [TTS] 播放翻譯: \(text.prefix(30))... (語言: \(langCode))")

            // ⭐️ 合成語音（在後台執行，不阻塞轉錄）
            let audioData = try await ttsService.synthesize(
                text: text,
                languageCode: langCode,
                gender: "female",
                useMultilingual: true
            )

            // ⭐️ 合成完成，更新 UI 並播放
            await MainActor.run {
                isSynthesizing = false
            }

            // 播放
            try ttsService.play(audioData: audioData)

            await MainActor.run {
                isPlaying = true
            }

            // ⭐️ 監聽播放結束（獨立 Task，不阻塞）
            // Capture ttsService 的引用，避免 struct 的 weak 問題
            let ttsServiceRef = ttsService
            Task {
                while ttsServiceRef.isPlaying {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }

                await MainActor.run {
                    isPlaying = false
                }
            }

        } catch {
            print("❌ TTS Error: \(error.localizedDescription)")
            await MainActor.run {
                isSynthesizing = false
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String

    var body: some View {
        NavigationStack {
            Form {
                Section("伺服器設定") {
                    TextField("伺服器 URL", text: $serverURL)
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
        }
    }
}

#Preview {
    ContentView()
}
