//
//  StoreKitService.swift
//  ios_realtime_trans
//
//  StoreKit 2 購買服務 - 處理 In-App Purchase 額度包購買
//

import Foundation
import StoreKit

// MARK: - 產品定義

/// 額度包產品配置
enum CreditProduct: String, CaseIterable, Identifiable {
    case starterPack = "starter_pack"   // NT$30 - 5萬額度（限購一次）
    case credits12 = "credits_12"       // NT$199 - 12萬額度（10+2萬贈送）
    case credits35 = "credits_35"       // NT$499 - 35萬額度（25+10萬贈送）
    case credits100 = "credits_100"     // NT$999 - 100萬額度（50+50萬贈送）

    var id: String { rawValue }

    /// 對應的額度數量
    var creditsAmount: Int {
        switch self {
        case .starterPack: return 50_000
        case .credits12: return 120_000
        case .credits35: return 350_000
        case .credits100: return 1_000_000
        }
    }

    /// 基礎額度（不含贈送）
    var baseCredits: Int {
        switch self {
        case .starterPack: return 50_000
        case .credits12: return 100_000
        case .credits35: return 250_000
        case .credits100: return 500_000
        }
    }

    /// 贈送額度
    var bonusCredits: Int {
        switch self {
        case .starterPack: return 0
        case .credits12: return 20_000
        case .credits35: return 100_000
        case .credits100: return 500_000
        }
    }

    /// 顯示名稱
    var displayName: String {
        switch self {
        case .starterPack: return "新手禮包"
        case .credits12: return "超值包"
        case .credits35: return "豪華包"
        case .credits100: return "尊爵包"
        }
    }

    /// 額度格式化顯示（簡短版）
    var creditsFormatted: String {
        switch self {
        case .starterPack: return "5萬"
        case .credits12: return "12萬"
        case .credits35: return "35萬"
        case .credits100: return "100萬"
        }
    }

    /// 額度詳細顯示（含贈送說明）
    var creditsDetailText: String {
        switch self {
        case .starterPack: return "5萬額度"
        case .credits12: return "10萬 + 2萬"
        case .credits35: return "25萬 + 10萬"
        case .credits100: return "50萬 + 50萬"
        }
    }

    /// 贈送標籤
    var bonusLabel: String? {
        switch self {
        case .starterPack: return "限購一次"
        case .credits12: return "贈送2萬"
        case .credits35: return "贈送10萬"
        case .credits100: return "贈送50萬"
        }
    }

    /// 是否為限購產品
    var isLimitedPurchase: Bool {
        self == .starterPack
    }

    /// 圖標名稱
    var iconName: String {
        switch self {
        case .starterPack: return "gift.fill"
        case .credits12: return "star.fill"
        case .credits35: return "crown.fill"
        case .credits100: return "sparkles"
        }
    }

    /// 圖標顏色
    var iconColorName: String {
        switch self {
        case .starterPack: return "green"
        case .credits12: return "blue"
        case .credits35: return "purple"
        case .credits100: return "orange"
        }
    }

    /// 排序順序
    var sortOrder: Int {
        switch self {
        case .starterPack: return 0
        case .credits12: return 1
        case .credits35: return 2
        case .credits100: return 3
        }
    }
}

// MARK: - 購買狀態

enum PurchaseState: Equatable {
    case idle
    case loading
    case purchasing
    case success(credits: Int)
    case failed(error: String)
}

// MARK: - StoreKit 服務

@Observable
final class StoreKitService {

    // MARK: - Singleton

    static let shared = StoreKitService()

    // MARK: - Properties

    /// 可用的產品列表
    private(set) var products: [Product] = []

    /// 購買狀態
    private(set) var purchaseState: PurchaseState = .idle

    /// 是否正在載入產品
    private(set) var isLoadingProducts: Bool = false

    /// 交易監聽任務
    private var transactionListener: Task<Void, Error>?

    // MARK: - Initialization

    private init() {
        // 開始監聽交易更新
        transactionListener = listenForTransactions()

        // 載入產品
        Task {
            await loadProducts()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - 產品載入

    /// 載入所有產品
    @MainActor
    func loadProducts() async {
        isLoadingProducts = true

        let productIds = CreditProduct.allCases.map { $0.rawValue }

        do {
            print("💰 [StoreKit] 載入產品: \(productIds)")
            let storeProducts = try await Product.products(for: productIds)

            // 按自定義順序排序
            products = storeProducts.sorted { p1, p2 in
                let order1 = CreditProduct(rawValue: p1.id)?.sortOrder ?? 99
                let order2 = CreditProduct(rawValue: p2.id)?.sortOrder ?? 99
                return order1 < order2
            }

            print("✅ [StoreKit] 成功載入 \(products.count) 個產品")
            for product in products {
                print("   - \(product.id): \(product.displayName) - \(product.displayPrice)")
            }

        } catch {
            print("❌ [StoreKit] 載入產品失敗: \(error.localizedDescription)")
        }

        isLoadingProducts = false
    }

    // MARK: - 購買

    /// 購買指定產品
    @MainActor
    func purchase(_ product: Product) async {
        purchaseState = .purchasing

        do {
            print("💰 [StoreKit] 開始購買: \(product.id)")

            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                // 驗證交易
                let transaction = try checkVerified(verification)

                // 獲取額度數量
                guard let creditProduct = CreditProduct(rawValue: product.id) else {
                    throw StoreKitError.unknownProduct
                }

                let creditsToAdd = creditProduct.creditsAmount

                // 更新 Firebase 額度
                await addCreditsToFirebase(credits: creditsToAdd, product: creditProduct)

                // 完成交易
                await transaction.finish()

                print("✅ [StoreKit] 購買成功: +\(creditsToAdd) 額度")
                purchaseState = .success(credits: creditsToAdd)

            case .userCancelled:
                print("⚠️ [StoreKit] 用戶取消購買")
                purchaseState = .idle

            case .pending:
                print("⏳ [StoreKit] 購買等待中（需要家長批准等）")
                purchaseState = .idle

            @unknown default:
                print("❓ [StoreKit] 未知購買結果")
                purchaseState = .idle
            }

        } catch {
            print("❌ [StoreKit] 購買失敗: \(error.localizedDescription)")
            purchaseState = .failed(error: error.localizedDescription)
        }
    }

    /// 重置購買狀態
    @MainActor
    func resetPurchaseState() {
        purchaseState = .idle
    }

    // MARK: - 交易監聽

    /// 監聽交易更新（處理未完成的交易、退款等）
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    // 處理交易
                    await self.handleTransaction(transaction)

                    // 完成交易
                    await transaction.finish()

                } catch {
                    print("❌ [StoreKit] 交易驗證失敗: \(error)")
                }
            }
        }
    }

    /// 處理交易
    private func handleTransaction(_ transaction: Transaction) async {
        guard let creditProduct = CreditProduct(rawValue: transaction.productID) else {
            print("⚠️ [StoreKit] 未知產品 ID: \(transaction.productID)")
            return
        }

        print("💰 [StoreKit] 處理交易: \(transaction.productID)")

        // 檢查是否是退款
        if transaction.revocationDate != nil {
            print("⚠️ [StoreKit] 交易已退款")
            // 可選：從用戶帳戶扣除額度
            return
        }

        // 添加額度
        await addCreditsToFirebase(credits: creditProduct.creditsAmount, product: creditProduct)
    }

    // MARK: - 驗證

    /// 驗證交易
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let signedType):
            return signedType
        }
    }

    // MARK: - Firebase 整合

    /// 添加額度到 Firebase
    private func addCreditsToFirebase(credits: Int, product: CreditProduct) async {
        guard AuthService.shared.currentUser != nil else {
            print("❌ [StoreKit] 無法添加額度：用戶未登入")
            return
        }

        do {
            // 使用 AuthService 的方法更新額度
            try await AuthService.shared.addCredits(credits)
            print("✅ [StoreKit] Firebase 額度已更新: +\(credits)")

            // 如果是新手禮包，記錄已購買
            if product.isLimitedPurchase {
                try await AuthService.shared.markStarterPackClaimed()
                print("✅ [StoreKit] 已標記新手禮包已領取")
            }

        } catch {
            print("❌ [StoreKit] Firebase 額度更新失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 恢復購買

    /// 恢復購買（對於消耗型產品，主要用於確保未完成的交易被處理）
    @MainActor
    func restorePurchases() async {
        purchaseState = .loading

        do {
            // 同步所有交易
            try await AppStore.sync()
            print("✅ [StoreKit] 購買同步完成")
            purchaseState = .idle

        } catch {
            print("❌ [StoreKit] 恢復購買失敗: \(error.localizedDescription)")
            purchaseState = .failed(error: error.localizedDescription)
        }
    }

    // MARK: - 輔助方法

    /// 根據產品 ID 獲取 Product
    func product(for creditProduct: CreditProduct) -> Product? {
        return products.first { $0.id == creditProduct.rawValue }
    }

    /// 獲取產品價格顯示
    func priceDisplay(for creditProduct: CreditProduct) -> String {
        if let product = product(for: creditProduct) {
            return product.displayPrice
        }
        return "---"
    }
}

// MARK: - 錯誤類型

enum StoreKitError: Error, LocalizedError {
    case unknownProduct
    case purchaseFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unknownProduct:
            return "未知的產品"
        case .purchaseFailed:
            return "購買失敗"
        case .verificationFailed:
            return "交易驗證失敗"
        }
    }
}
