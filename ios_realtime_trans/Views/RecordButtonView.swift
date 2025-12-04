//
//  RecordButtonView.swift
//  ios_realtime_trans
//
//  滑動通話按鈕：往右滑開始通話，往左滑結束通話
//

import SwiftUI

struct RecordButtonView: View {
    let isRecording: Bool
    let action: () -> Void

    // 滑動狀態
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    // 尺寸常數
    private let trackWidth: CGFloat = 280
    private let trackHeight: CGFloat = 70
    private let thumbSize: CGFloat = 60
    private let threshold: CGFloat = 0.7  // 滑動超過 70% 觸發

    // 計算滑動範圍
    private var maxOffset: CGFloat {
        trackWidth - thumbSize - 10  // 減去 padding
    }

    // 計算當前位置（0 = 左邊/結束, 1 = 右邊/開始）
    private var currentPosition: CGFloat {
        if isRecording {
            // 通話中：按鈕在右邊，可以往左滑
            return max(0, min(1, 1 + dragOffset / maxOffset))
        } else {
            // 未通話：按鈕在左邊，可以往右滑
            return max(0, min(1, dragOffset / maxOffset))
        }
    }

    // 背景顏色
    private var trackColor: Color {
        if isRecording {
            return Color.red.opacity(0.2)
        } else {
            return Color.green.opacity(0.2)
        }
    }

    // 按鈕顏色
    private var thumbColor: LinearGradient {
        if isRecording {
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
        ZStack {
            // 背景軌道
            RoundedRectangle(cornerRadius: trackHeight / 2)
                .fill(trackColor)
                .frame(width: trackWidth, height: trackHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: trackHeight / 2)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 左邊圖標（結束通話）
            HStack {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .foregroundStyle(.red.opacity(isRecording ? 0.8 : 0.3))
                    .padding(.leading, 20)
                Spacer()
            }
            .frame(width: trackWidth)

            // 右邊圖標（開始通話）
            HStack {
                Spacer()
                Image(systemName: "phone.fill")
                    .font(.title2)
                    .foregroundStyle(.green.opacity(isRecording ? 0.3 : 0.8))
                    .padding(.trailing, 20)
            }
            .frame(width: trackWidth)

            // 中間提示文字
            Text(isRecording ? "← 滑動結束" : "滑動開始 →")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            // 可滑動的按鈕
            HStack {
                if !isRecording {
                    Spacer()
                        .frame(width: dragOffset)
                }

                // 圓形滑塊
                Circle()
                    .fill(thumbColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: isRecording ? .red.opacity(0.4) : .green.opacity(0.4), radius: 8, x: 0, y: 4)
                    .overlay(
                        Image(systemName: isRecording ? "waveform" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    )
                    .scaleEffect(isDragging ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isDragging)

                if isRecording {
                    Spacer()
                        .frame(width: -dragOffset)
                }
            }
            .frame(width: trackWidth - 10, alignment: isRecording ? .trailing : .leading)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        if isRecording {
                            // 通話中：只能往左滑（負值）
                            dragOffset = min(0, max(-maxOffset, value.translation.width))
                        } else {
                            // 未通話：只能往右滑（正值）
                            dragOffset = max(0, min(maxOffset, value.translation.width))
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        let progress = abs(dragOffset) / maxOffset

                        if progress > threshold {
                            // 超過閾值，觸發操作
                            withAnimation(.spring(response: 0.3)) {
                                dragOffset = 0
                            }
                            // 觸覺反饋
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            // 執行操作
                            action()
                        } else {
                            // 未超過閾值，彈回原位
                            withAnimation(.spring(response: 0.3)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
        .frame(width: trackWidth, height: trackHeight)
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
