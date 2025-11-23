//
//  RecordButtonView.swift
//  ios_realtime_trans
//
//  錄音按鈕視圖元件
//

import SwiftUI

struct RecordButtonView: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var isAnimating = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.title3)

                Text(isRecording ? "停止錄音" : "開始錄音")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: isRecording
                        ? [Color.pink, Color.red]
                        : [Color.purple, Color.indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(50)
            .shadow(
                color: (isRecording ? Color.red : Color.purple).opacity(0.4),
                radius: 10,
                x: 0,
                y: 5
            )
            .scaleEffect(isAnimating && isRecording ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording, initial: true) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            } else {
                withAnimation {
                    isAnimating = false
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        RecordButtonView(isRecording: false) {
            print("Start recording")
        }

        RecordButtonView(isRecording: true) {
            print("Stop recording")
        }
    }
    .padding()
}
