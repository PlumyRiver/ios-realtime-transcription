//
//  PurchaseView.swift
//  ios_realtime_trans
//
//  購買額度包介面 - 促銷頁面設計
//

import SwiftUI
import StoreKit

struct PurchaseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var storeService = StoreKitService.shared
    @State private var authService = AuthService.shared
    @State private var showSuccessAlert = false
    @State private var purchasedCredits = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 促銷橫幅
                    promotionBanner

                    // 當前額度顯示
                    currentCreditsCard

                    // 產品列表
                    if storeService.isLoadingProducts {
                        ProgressView("載入中...")
                            .padding(.top, 40)
                    } else if storeService.products.isEmpty {
                        emptyProductsView
                    } else {
                        productsSection
                    }

                    // 恢復購買按鈕
                    restorePurchaseButton
                        .padding(.top, 8)

                    // 說明文字
                    disclaimerText
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [Color(.systemBackground), Color.orange.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .navigationTitle("購買額度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("購買成功", isPresented: $showSuccessAlert) {
                Button("確定") {
                    showSuccessAlert = false
                }
            } message: {
                Text("已成功增加 \(formatNumber(purchasedCredits)) 額度！")
            }
            .onChange(of: storeService.purchaseState) { _, newState in
                if case .success(let credits) = newState {
                    purchasedCredits = credits
                    showSuccessAlert = true
                    storeService.resetPurchaseState()
                }
            }
        }
    }

    // MARK: - 促銷橫幅

    private var promotionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("限時促銷中")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text("額外贈送最高 50% 額度！")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
        .padding()
        .background(
            LinearGradient(
                colors: [.orange, .red.opacity(0.8)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .orange.opacity(0.3), radius: 8, y: 4)
    }

    // MARK: - 當前額度卡片

    private var currentCreditsCard: some View {
        VStack(spacing: 8) {
            Text("目前額度")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(formatNumber(authService.currentUser?.slowCredits ?? 0))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("額度")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        )
    }

    // MARK: - 產品區塊

    private var productsSection: some View {
        VStack(spacing: 16) {
            // 新手禮包（如果尚未領取）
            if !hasClaimedStarterPack {
                if let product = storeService.product(for: .starterPack) {
                    StarterPackCard(
                        product: product,
                        isPurchasing: isPurchasing(.starterPack)
                    ) {
                        Task {
                            await storeService.purchase(product)
                        }
                    }
                }
            }

            // 其他額度包
            Text("額度包")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            ForEach([CreditProduct.credits12, .credits35, .credits100], id: \.id) { creditProduct in
                if let product = storeService.product(for: creditProduct) {
                    ProductCard(
                        creditProduct: creditProduct,
                        product: product,
                        isPurchasing: isPurchasing(creditProduct)
                    ) {
                        Task {
                            await storeService.purchase(product)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 空產品視圖

    private var emptyProductsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("無法載入產品")
                .font(.headline)

            Text("請檢查網路連線或稍後再試")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("重新載入") {
                Task {
                    await storeService.loadProducts()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 40)
    }

    // MARK: - 恢復購買按鈕

    private var restorePurchaseButton: some View {
        Button {
            Task {
                await storeService.restorePurchases()
            }
        } label: {
            Text("恢復購買")
                .font(.subheadline)
                .foregroundStyle(.blue)
        }
        .disabled(storeService.purchaseState == .loading)
    }

    // MARK: - 說明文字

    private var disclaimerText: some View {
        VStack(spacing: 8) {
            Text("購買後額度將立即添加到您的帳戶")
            Text("額度不會過期，可隨時使用")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.vertical)
    }

    // MARK: - 輔助方法

    private var hasClaimedStarterPack: Bool {
        authService.currentUser?.hasClaimedStarterPack ?? false
    }

    private func isPurchasing(_ creditProduct: CreditProduct) -> Bool {
        if case .purchasing = storeService.purchaseState {
            return true
        }
        return false
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

// MARK: - 新手禮包卡片（特殊設計）

struct StarterPackCard: View {
    let product: Product
    let isPurchasing: Bool
    let onPurchase: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 頂部標籤
            HStack {
                Image(systemName: "gift.fill")
                    .foregroundStyle(.white)
                Text("新手專屬")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green)
            .clipShape(Capsule())
            .offset(y: 14)
            .zIndex(1)

            // 卡片內容
            HStack(spacing: 16) {
                // 圖標
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 60, height: 60)

                    Image(systemName: "gift.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                }

                // 產品資訊
                VStack(alignment: .leading, spacing: 4) {
                    Text("新手禮包")
                        .font(.headline)
                        .fontWeight(.bold)

                    HStack(spacing: 4) {
                        Text("5萬")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                        Text("額度")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("限購一次，超值入門")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 購買按鈕
                Button {
                    onPurchase()
                } label: {
                    if isPurchasing {
                        ProgressView()
                            .frame(width: 80)
                    } else {
                        Text(product.displayPrice)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 80)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [.green, .green.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(Capsule())
                    }
                }
                .disabled(isPurchasing)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .green.opacity(0.2), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
            )
        }
    }
}

// MARK: - 產品卡片

struct ProductCard: View {
    let creditProduct: CreditProduct
    let product: Product
    let isPurchasing: Bool
    let onPurchase: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // 圖標
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 56, height: 56)

                Image(systemName: creditProduct.iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)
            }

            // 產品資訊
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(creditProduct.displayName)
                        .font(.headline)

                    if let bonus = creditProduct.bonusLabel {
                        Text(bonus)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.orange))
                    }
                }

                // 額度詳情（含贈送說明）
                HStack(spacing: 4) {
                    Text(creditProduct.creditsDetailText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(iconColor)

                    Text("額度")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 總額度說明
                Text("共 \(creditProduct.creditsFormatted) 額度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 購買按鈕
            Button {
                onPurchase()
            } label: {
                if isPurchasing {
                    ProgressView()
                        .frame(width: 80)
                } else {
                    Text(product.displayPrice)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 80)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [iconColor, iconColor.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(Capsule())
                }
            }
            .disabled(isPurchasing)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        )
    }

    private var iconColor: Color {
        switch creditProduct.iconColorName {
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        default: return .blue
        }
    }
}

// MARK: - Preview

#Preview {
    PurchaseView()
}
