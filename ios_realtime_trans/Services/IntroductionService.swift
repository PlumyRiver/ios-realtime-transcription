//
//  IntroductionService.swift
//  ios_realtime_trans
//
//  從 Firestore 讀取語言介紹文字，在對話開始時顯示雙語提示
//

import Foundation
import FirebaseFirestore

class IntroductionService {
    static let shared = IntroductionService()

    private let db: Firestore

    /// 記憶體快取（避免重複讀取）
    private var cache: [String: IntroductionData] = [:]

    private init() {
        db = Firestore.firestore(database: "realtime-voice-database")
    }

    /// 語言介紹資料結構
    struct IntroductionData {
        let sourceIntro: String   // 來源語言的介紹文字
        let targetIntro: String   // 目標語言的介紹文字
    }

    /// 取得語言對的介紹文字
    /// - Parameters:
    ///   - sourceLang: 來源語言代碼 (e.g., "zh")
    ///   - targetLang: 目標語言代碼 (e.g., "en")
    /// - Returns: 雙語介紹文字，找不到時回傳 nil
    func fetchIntroduction(sourceLang: String, targetLang: String) async -> IntroductionData? {
        let directKey = "\(sourceLang)_\(targetLang)"
        let reverseKey = "\(targetLang)_\(sourceLang)"

        // 1. 檢查快取
        if let cached = cache[directKey] {
            print("📋 [Introduction] 使用快取: \(directKey)")
            return cached
        }
        if let cached = cache[reverseKey] {
            print("📋 [Introduction] 使用快取（反向）: \(reverseKey)")
            return cached
        }

        // 2. 從 Firestore 讀取（先嘗試直接 key，再嘗試反向）
        if let data = await fetchFromFirestore(key: directKey, sourceLang: sourceLang, targetLang: targetLang) {
            cache[directKey] = data
            return data
        }

        if let data = await fetchFromFirestore(key: reverseKey, sourceLang: sourceLang, targetLang: targetLang) {
            cache[reverseKey] = data
            return data
        }

        print("⚠️ [Introduction] 找不到語言對: \(directKey) 或 \(reverseKey)")
        return nil
    }

    private func fetchFromFirestore(key: String, sourceLang: String, targetLang: String) async -> IntroductionData? {
        do {
            let doc = try await db.collection("language_introductions").document(key).getDocument()

            guard let data = doc.data(),
                  let introductions = data["introductions"] as? [String: String] else {
                return nil
            }

            // 取得來源語言和目標語言的介紹文字
            guard let sourceText = introductions[sourceLang],
                  let targetText = introductions[targetLang] else {
                // 可能 key 是反向的，嘗試反過來取
                if let sourceText = introductions[targetLang],
                   let targetText = introductions[sourceLang] {
                    // 反向：source/target 對調
                    print("📖 [Introduction] 從 Firestore 讀取（反向匹配）: \(key)")
                    return IntroductionData(sourceIntro: targetText, targetIntro: sourceText)
                }
                return nil
            }

            print("📖 [Introduction] 從 Firestore 讀取: \(key)")
            return IntroductionData(sourceIntro: sourceText, targetIntro: targetText)

        } catch {
            print("❌ [Introduction] Firestore 讀取失敗: \(error.localizedDescription)")
            return nil
        }
    }
}
