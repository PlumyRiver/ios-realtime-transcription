//
//  StatsView.swift
//  ios_realtime_trans
//
//  統計數據視圖元件
//

import SwiftUI

struct StatsView: View {
    let transcriptCount: Int
    let wordCount: Int
    let recordingDuration: Int

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                value: "\(transcriptCount)",
                label: "轉錄次數",
                icon: "text.bubble"
            )

            StatCard(
                value: "\(wordCount)",
                label: "總字數",
                icon: "character.cursor.ibeam"
            )

            StatCard(
                value: formatDuration(recordingDuration),
                label: "錄音時長",
                icon: "clock"
            )
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
}

struct StatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
            }
            Text(label)
                .font(.caption)
                .opacity(0.9)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.purple, Color.purple.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
        .cornerRadius(10)
    }
}

#Preview {
    StatsView(
        transcriptCount: 5,
        wordCount: 128,
        recordingDuration: 65
    )
    .padding()
}
