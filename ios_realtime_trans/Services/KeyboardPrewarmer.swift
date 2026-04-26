//
//  KeyboardPrewarmer.swift
//  ios_realtime_trans
//
//  預熱 iOS 鍵盤（含中文輸入法、QuickType、字典）
//  避免第一次使用 TextField 時卡 0.5-1 秒
//

import UIKit

enum KeyboardPrewarmer {
    /// 已預熱過（避免重複）
    private static var hasPrewarmed = false

    /// 在背景預熱鍵盤（於啟動風暴結束後呼叫）
    /// 原理：建一個隱藏 UITextField，短暫成為 first responder 觸發 iOS 載入鍵盤
    @MainActor
    static func prewarm() {
        guard !hasPrewarmed else { return }

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            print("⚠️ [KeyboardPrewarmer] 找不到 key window")
            return
        }

        hasPrewarmed = true

        let textField = UITextField()
        textField.isHidden = true  // 完全看不見
        textField.frame = .zero
        window.addSubview(textField)

        textField.becomeFirstResponder()
        print("⌨️ [KeyboardPrewarmer] 開始預熱鍵盤")

        // 50ms 後解除，避免鍵盤真的彈出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textField.resignFirstResponder()
            textField.removeFromSuperview()
            print("⌨️ [KeyboardPrewarmer] 鍵盤預熱完成")
        }
    }

    /// 鍵盤預熱一定要碰主執行緒；只在 UI 閒置時嘗試，避免搶走啟動或輸入中的互動。
    @MainActor
    static func prewarmWhenIdle(
        maxAttempts: Int = 6,
        initialDelay: UInt64 = 1_500_000_000,
        retryDelay: UInt64 = 1_500_000_000,
        shouldRun: @escaping @MainActor () -> Bool
    ) async {
        guard !hasPrewarmed else { return }

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return }

            let delay = attempt == 0 ? initialDelay : retryDelay
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            let appIsActive = UIApplication.shared.applicationState == .active
            if appIsActive && shouldRun() {
                await Task.yield()
                guard shouldRun() else { continue }
                prewarm()
                return
            }
        }

        print("⌨️ [KeyboardPrewarmer] UI 忙碌，延後到下次需要時再預熱")
    }
}
