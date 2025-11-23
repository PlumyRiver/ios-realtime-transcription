//
//  StatusBarView.swift
//  ios_realtime_trans
//
//  狀態欄視圖元件
//

import SwiftUI

struct StatusBarView: View {
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 10) {
            // 狀態指示燈
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .modifier(PulseModifier(isAnimating: status.statusType == .recording))

            Text(status.displayText)
                .font(.subheadline)
                .foregroundStyle(statusColor)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(backgroundColor)
        .cornerRadius(10)
    }

    private var statusColor: Color {
        switch status.statusType {
        case .idle:
            return .blue
        case .recording:
            return .orange
        case .processing:
            return .purple
        case .error:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch status.statusType {
        case .idle:
            return Color.blue.opacity(0.1)
        case .recording:
            return Color.orange.opacity(0.1)
        case .processing:
            return Color.purple.opacity(0.1)
        case .error:
            return Color.red.opacity(0.1)
        }
    }
}

// MARK: - Pulse Animation Modifier

struct PulseModifier: ViewModifier {
    let isAnimating: Bool
    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(isAnimating ? (scale == 1.0 ? 1.0 : 0.3) : 1.0)
            .onChange(of: isAnimating, initial: true) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                        scale = 1.5
                    }
                } else {
                    withAnimation {
                        scale = 1.0
                    }
                }
            }
    }
}

#Preview {
    VStack(spacing: 16) {
        StatusBarView(status: .disconnected)
        StatusBarView(status: .connecting)
        StatusBarView(status: .connected)
        StatusBarView(status: .recording)
        StatusBarView(status: .error("連接失敗"))
    }
    .padding()
}
