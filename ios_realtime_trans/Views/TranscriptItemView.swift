//
//  TranscriptItemView.swift
//  ios_realtime_trans
//
//  單個轉錄結果的視圖元件
//

import SwiftUI
import UIKit

struct TranscriptItemView: View {
    let transcript: TranscriptMessage

    // 複製反饋狀態
    @State private var showCopiedFeedback = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 對話框主體
            VStack(alignment: .leading, spacing: 8) {
                // 主要文字
                HStack(alignment: .top, spacing: 8) {
                    // 說話者標籤
                    if let speakerTag = transcript.speakerTag {
                        Text("Speaker \(speakerTag):")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                    }

                    Text(transcript.text)
                        .font(.body)
                        .foregroundStyle(transcript.isFinal ? .primary : .secondary)
                }

                // 翻譯文字
                if transcript.hasSegmentedTranslation, let segments = transcript.translationSegments {
                    // ⭐️ 分句顯示：每句原文對應一句翻譯
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 2) {
                                // 原文片段（灰色小字）
                                Text(segment.original)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                // 翻譯片段
                                HStack(spacing: 4) {
                                    // 完整性標記
                                    Image(systemName: segment.isComplete ? "checkmark.circle.fill" : "ellipsis.circle")
                                        .font(.caption2)
                                        .foregroundStyle(segment.isComplete ? .green : .orange)

                                    Text(segment.translation)
                                        .font(.subheadline)
                                        .italic()
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)
                } else if let translation = transcript.translation {
                    // 單句翻譯（原有邏輯）
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption)
                        Text(translation)
                            .font(.subheadline)
                            .italic()
                    }
                    .foregroundStyle(.blue)
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }

                // 元數據（只顯示最終結果）
                if transcript.isFinal {
                    HStack(spacing: 12) {
                        // 時間
                        Label {
                            Text(formatTime(transcript.timestamp))
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        // 信心度
                        if transcript.confidence > 0 {
                            ConfidenceBadge(confidence: transcript.confidence)
                        }

                        // 語言
                        if let language = transcript.language {
                            Label {
                                Text(language)
                            } icon: {
                                Image(systemName: "globe")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        // 簡繁轉換標記
                        if transcript.converted {
                            Label {
                                Text("已轉繁體")
                            } icon: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .font(.caption)
                            .foregroundStyle(.green)
                        }
                    }
                } else {
                    // Interim 標記
                    Label {
                        Text("識別中...")
                    } icon: {
                        Image(systemName: "ellipsis")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundForSpeaker)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(borderColorForSpeaker)
                    .frame(width: 4)
            }
            .cornerRadius(10)
            .opacity(transcript.isFinal ? 1.0 : 0.7)
            .animation(.easeInOut(duration: 0.3), value: transcript.isFinal)

            // 複製按鈕（只在有翻譯時顯示）
            if transcript.isFinal && hasTranslation {
                Button {
                    copyAllContent()
                } label: {
                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 16))
                        .foregroundStyle(showCopiedFeedback ? .green : .secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
            }
        }
    }

    // MARK: - Helpers

    /// 是否有翻譯內容
    private var hasTranslation: Bool {
        transcript.translation != nil || transcript.hasSegmentedTranslation
    }

    /// 複製所有內容（原文 + 翻譯）
    private func copyAllContent() {
        var content = transcript.text

        if transcript.hasSegmentedTranslation, let segments = transcript.translationSegments {
            // 分句翻譯：合併所有翻譯
            let translations = segments.map { $0.translation }.joined(separator: " ")
            content += "\n\n" + translations
        } else if let translation = transcript.translation {
            // 單句翻譯
            content += "\n\n" + translation
        }

        UIPasteboard.general.string = content

        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedFeedback = true
        }

        // 1.5 秒後自動隱藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedFeedback = false
            }
        }
    }

    private var backgroundForSpeaker: Color {
        guard let speakerTag = transcript.speakerTag else {
            return transcript.isFinal ? Color(.systemBackground) : Color(.systemGray6)
        }

        let colors: [Color] = [
            Color.blue.opacity(0.1),
            Color.purple.opacity(0.1),
            Color.orange.opacity(0.1),
            Color.green.opacity(0.1),
            Color.pink.opacity(0.1),
            Color.yellow.opacity(0.1)
        ]

        return colors[(speakerTag - 1) % colors.count]
    }

    private var borderColorForSpeaker: Color {
        guard let speakerTag = transcript.speakerTag else {
            return transcript.isFinal ? Color.purple : Color.gray
        }

        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .yellow]
        return colors[(speakerTag - 1) % colors.count]
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int(confidence * 100))%")
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .cornerRadius(4)
    }

    private var backgroundColor: Color {
        if confidence >= 0.85 {
            return Color.green.opacity(0.2)
        } else if confidence >= 0.7 {
            return Color.yellow.opacity(0.2)
        } else {
            return Color.orange.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        if confidence >= 0.85 {
            return .green
        } else if confidence >= 0.7 {
            return .orange
        } else {
            return .red
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        TranscriptItemView(
            transcript: TranscriptMessage(
                text: "這是一段測試文字",
                isFinal: true,
                confidence: 0.95,
                language: "zh-TW",
                translation: "This is a test text"
            )
        )

        TranscriptItemView(
            transcript: TranscriptMessage(
                text: "正在識別中的文字...",
                isFinal: false
            )
        )

        // ⭐️ 分句翻譯範例
        TranscriptItemView(
            transcript: TranscriptMessage(
                text: "今天天氣很好我想出去走走順便買杯咖啡",
                isFinal: true,
                confidence: 0.92,
                language: "zh-TW",
                translationSegments: [
                    TranslationSegment(original: "今天天氣很好", translation: "The weather is nice today", isComplete: true),
                    TranslationSegment(original: "我想出去走走", translation: "I want to go out for a walk", isComplete: true),
                    TranslationSegment(original: "順便買杯咖啡", translation: "and get a cup of coffee", isComplete: false)
                ]
            )
        )

        TranscriptItemView(
            transcript: TranscriptMessage(
                text: "Speaker 1 的對話",
                isFinal: true,
                confidence: 0.88,
                language: "zh-TW",
                speakerTag: 1
            )
        )
    }
    .padding()
}
