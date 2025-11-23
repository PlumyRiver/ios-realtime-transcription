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
            ScrollView {
                VStack(spacing: 20) {
                    // 統計卡片
                    StatsView(
                        transcriptCount: viewModel.transcriptCount,
                        wordCount: viewModel.wordCount,
                        recordingDuration: viewModel.recordingDuration
                    )

                    // 控制區塊
                    VStack(spacing: 16) {
                        // 語言選擇
                        LanguageSelectorView(
                            sourceLang: $viewModel.sourceLang,
                            targetLang: $viewModel.targetLang,
                            isDisabled: viewModel.isRecording
                        )

                        // 錄音按鈕和清除按鈕
                        HStack(spacing: 16) {
                            RecordButtonView(
                                isRecording: viewModel.isRecording
                            ) {
                                Task {
                                    await viewModel.toggleRecording()
                                }
                            }

                            Button {
                                viewModel.clearTranscripts()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "trash")
                                    Text("清除")
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                            }
                            .disabled(viewModel.isRecording || viewModel.transcripts.isEmpty)
                        }

                        // 狀態欄
                        StatusBarView(status: viewModel.status)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

                    // 轉錄結果區塊
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("轉錄結果")
                                .font(.headline)

                            Spacer()

                            if !viewModel.transcripts.isEmpty {
                                Text("\(viewModel.transcripts.count) 條記錄")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if viewModel.transcripts.isEmpty && viewModel.interimTranscript == nil {
                            // 空狀態
                            EmptyTranscriptView()
                        } else {
                            // 轉錄列表
                            LazyVStack(spacing: 12) {
                                // Interim 結果（正在識別中）
                                if let interim = viewModel.interimTranscript {
                                    TranscriptItemView(transcript: interim)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }

                                // 最終結果
                                ForEach(viewModel.transcripts) { transcript in
                                    TranscriptItemView(transcript: transcript)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .animation(.easeInOut(duration: 0.3), value: viewModel.transcripts.count)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.6), Color.indigo.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Chirp3 語音轉錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(serverURL: $viewModel.serverURL)
            }
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - Empty State View

struct EmptyTranscriptView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)

            Text("尚無轉錄結果")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("開始錄音後，轉錄文字將顯示在這裡")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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

                    Text("例如：192.168.1.100:3008 或 your-server.com:3008")
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
