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
        // 初始化 Firebase
        FirebaseApp.configure()
        print("✅ [App] Firebase 已初始化")

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
    // ⭐️ 使用獨立 View 來觀察 AuthService 的狀態變化
    @State private var authService = AuthService.shared

    /// 用戶是否主動登出過（用來判斷是否顯示登入頁面）
    @State private var userDidLogout = false

    var body: some View {
        Group {
            if authService.authState == .emailNotVerified {
                EmailVerificationView()
            } else if userDidLogout && authService.authState != .signedIn {
                LoginView()
            } else {
                // ⭐️ ContentView 只建立一次，auth 狀態變化不會銷毀重建
                ContentView()
                    .task { await autoSignInIfNeeded() }
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
