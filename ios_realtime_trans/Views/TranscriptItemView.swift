//
//  TranscriptItemView.swift
//  ios_realtime_trans
//
//  單個轉錄結果的視圖元件
//

import SwiftUI

struct TranscriptItemView: View {
    let transcript: TranscriptMessage

    var body: some View {
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
            if let translation = transcript.translation {
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
    }

    // MARK: - Helpers

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
