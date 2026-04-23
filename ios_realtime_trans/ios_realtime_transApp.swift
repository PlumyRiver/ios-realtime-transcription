//
//  ios_realtime_transApp.swift
//  ios_realtime_trans
//
//  Created by 吳東隆 on 2025/11/23.
//

import SwiftUI
import FirebaseCore
import GoogleSignIn

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let t0 = Date()
        FirebaseApp.configure()
        print("⏱️ [AppDelegate] FirebaseApp.configure: \(Int(Date().timeIntervalSince(t0)*1000))ms")

        return true
    }

    // 處理 Google Sign-In URL callback
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

// MARK: - Main App

@main
struct ios_realtime_transApp: App {
    // 註冊 App Delegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // 處理 Google Sign-In URL callback (Scene based)
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

// MARK: - Root View（獨立 View 才能正確觀察 @Observable）

struct RootView: View {
    @State private var authService = AuthService.shared
    @State private var userDidLogout = false

    /// ⭐️ ViewModel 在 RootView 持有 — 不管 ContentView 怎麼重建都不會丟失
    @State private var sharedViewModel = TranscriptionViewModel()

    var body: some View {
        ZStack {
            ContentView(viewModel: sharedViewModel)
                .task { await autoSignInIfNeeded() }

            if authService.authState == .emailNotVerified {
                EmailVerificationView()
                    .transition(.opacity)
            } else if userDidLogout && authService.authState != .signedIn {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authService.authState)
        .onChange(of: authService.authState) { oldValue, newValue in
            if oldValue == .signedIn && newValue == .signedOut {
                print("🔄 [App] 用戶主動登出")
                userDidLogout = true
            }
        }
    }

    /// 背景自動登入（完全不阻塞 UI）
    private func autoSignInIfNeeded() async {
        // 如果已經登入，不需要再登入
        guard authService.authState != .signedIn else { return }

        // ⭐️ 使用 Task.detached 完全脫離主線程
        Task.detached(priority: .utility) {
            print("🚀 [App] 背景嘗試設備 ID 自動登入...")

            do {
                try await AuthService.shared.signInWithDeviceId()
                print("✅ [App] 設備 ID 自動登入成功")
            } catch {
                print("⚠️ [App] 設備 ID 自動登入失敗: \(error.localizedDescription)")
                // 不顯示登入頁面，讓用戶繼續使用（功能受限）
            }
        }
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // App Icon
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                ProgressView()
                    .scaleEffect(1.2)

                Text("載入中...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
