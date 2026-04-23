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
        hasPrewarmed = true

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            print("⚠️ [KeyboardPrewarmer] 找不到 key window")
            return
        }

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
}
