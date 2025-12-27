//
//  LoginView.swift
//  ios_realtime_trans
//
//  登入/註冊介面
//

import SwiftUI
import FirebaseAuth
import AuthenticationServices

struct LoginView: View {

    @State private var authService = AuthService.shared

    // 輸入欄位
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""

    // UI 狀態
    @State private var isSignUpMode: Bool = false
    @State private var showForgotPassword: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                // 背景漸層
                LinearGradient(
                    colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 32) {
                        // Logo 和標題
                        headerSection

                        // 登入/註冊表單
                        formSection

                        // 分隔線
                        dividerSection

                        // 第三方登入按鈕
                        thirdPartySignInButtons

                        // 切換登入/註冊模式
                        switchModeButton
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 48)
                }
            }
            .navigationBarHidden(true)
            .alert(alertTitle, isPresented: $showAlert) {
                Button("確定", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .sheet(isPresented: $showForgotPassword) {
                ForgotPasswordView()
            }
            .disabled(authService.isLoading)
            .overlay {
                if authService.isLoading {
                    loadingOverlay
                }
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
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

            // App 名稱
            Text("開講 AI")
                .font(.largeTitle)
                .fontWeight(.bold)

            // 副標題
            Text("即時語音翻譯")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    // MARK: - Form Section

    private var formSection: some View {
        VStack(spacing: 16) {
            // Email 輸入
            VStack(alignment: .leading, spacing: 8) {
                Text("電子郵件")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("example@email.com", text: $email)
                    .textFieldStyle(.plain)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            }

            // 密碼輸入
            VStack(alignment: .leading, spacing: 8) {
                Text("密碼")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("至少 6 個字元", text: $password)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            }

            // 確認密碼（僅註冊模式）
            if isSignUpMode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("確認密碼")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField("再次輸入密碼", text: $confirmPassword)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }
            }

            // 忘記密碼（僅登入模式）
            if !isSignUpMode {
                HStack {
                    Spacer()
                    Button("忘記密碼？") {
                        showForgotPassword = true
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            // 主要按鈕（登入/註冊）
            Button {
                Task {
                    await handleEmailAuth()
                }
            } label: {
                Text(isSignUpMode ? "註冊" : "登入")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
            }
            .disabled(!isFormValid)
            .opacity(isFormValid ? 1 : 0.6)
        }
    }

    // MARK: - Divider Section

    private var dividerSection: some View {
        HStack {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color(.systemGray4))

            Text("或")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color(.systemGray4))
        }
    }

    // MARK: - Third Party Sign-In Buttons

    private var thirdPartySignInButtons: some View {
        VStack(spacing: 12) {
            // Apple 登入按鈕
            SignInWithAppleButton(.signIn) { request in
                let (appleRequest, hashedNonce) = authService.startAppleSignIn()
                request.requestedScopes = appleRequest.requestedScopes
                request.nonce = hashedNonce
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task {
                        do {
                            try await authService.completeAppleSignIn(authorization: authorization)
                        } catch {
                            showError("Apple 登入失敗", error.localizedDescription)
                        }
                    }
                case .failure(let error):
                    authService.handleAppleSignInError(error)
                    if let errorMsg = authService.errorMessage {
                        showError("Apple 登入失敗", errorMsg)
                    }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .cornerRadius(12)

            // Google 登入按鈕
            Button {
                Task {
                    await handleGoogleSignIn()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "g.circle.fill")
                        .font(.title2)

                    Text("使用 Google 帳號登入")
                        .font(.headline)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
            }

            // 設備登入按鈕（訪客模式）
            Button {
                Task {
                    await handleDeviceSignIn()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.title2)

                    Text("使用此設備繼續")
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Switch Mode Button

    private var switchModeButton: some View {
        HStack {
            Text(isSignUpMode ? "已有帳號？" : "還沒有帳號？")
                .foregroundStyle(.secondary)

            Button(isSignUpMode ? "登入" : "註冊") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSignUpMode.toggle()
                    clearForm()
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(.blue)
        }
        .font(.subheadline)
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)

                Text("處理中...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Form Validation

    private var isFormValid: Bool {
        let isEmailValid = !email.isEmpty && email.contains("@")
        let isPasswordValid = password.count >= 6

        if isSignUpMode {
            return isEmailValid && isPasswordValid && password == confirmPassword
        } else {
            return isEmailValid && isPasswordValid
        }
    }

    // MARK: - Actions

    private func handleEmailAuth() async {
        do {
            if isSignUpMode {
                try await authService.signUp(email: email, password: password)
                alertTitle = "註冊成功"
                alertMessage = "驗證郵件已發送到 \(email)，請點擊郵件中的連結完成驗證。"
                showAlert = true
            } else {
                try await authService.signIn(email: email, password: password)
                // 登入成功，AuthService 會自動更新狀態
            }
        } catch AuthError.emailNotVerified {
            alertTitle = "郵件未驗證"
            alertMessage = "請先驗證您的電子郵件。需要重新發送驗證郵件嗎？"
            showAlert = true
        } catch {
            alertTitle = "錯誤"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func handleGoogleSignIn() async {
        do {
            try await authService.signInWithGoogle()
            // 登入成功，AuthService 會自動更新狀態
        } catch AuthError.googleSignInFailed {
            // 用戶取消，不顯示錯誤
        } catch {
            alertTitle = "錯誤"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func handleDeviceSignIn() async {
        do {
            try await authService.signInWithDeviceId()
            // 登入成功，AuthService 會自動更新狀態
        } catch {
            alertTitle = "設備登入失敗"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func showError(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func clearForm() {
        email = ""
        password = ""
        confirmPassword = ""
    }
}

// MARK: - Forgot Password View

struct ForgotPasswordView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var authService = AuthService.shared
    @State private var email: String = ""
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var isSuccess: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // 圖示
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                    .padding(.top, 32)

                // 說明文字
                Text("輸入您的電子郵件，我們將發送密碼重設連結給您。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                // Email 輸入
                TextField("電子郵件", text: $email)
                    .textFieldStyle(.plain)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal)

                // 發送按鈕
                Button {
                    Task {
                        await sendResetEmail()
                    }
                } label: {
                    Text("發送重設郵件")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .disabled(email.isEmpty || !email.contains("@"))
                .opacity(email.isEmpty || !email.contains("@") ? 0.6 : 1)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("忘記密碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .alert(isSuccess ? "成功" : "錯誤", isPresented: $showAlert) {
                Button("確定") {
                    if isSuccess {
                        dismiss()
                    }
                }
            } message: {
                Text(alertMessage)
            }
            .disabled(authService.isLoading)
        }
    }

    private func sendResetEmail() async {
        do {
            try await authService.sendPasswordReset(email: email)
            isSuccess = true
            alertMessage = "密碼重設郵件已發送到 \(email)"
            showAlert = true
        } catch {
            isSuccess = false
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

// MARK: - Email Verification View

struct EmailVerificationView: View {

    @State private var authService = AuthService.shared
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 圖示
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)

            // 標題
            Text("驗證您的電子郵件")
                .font(.title)
                .fontWeight(.bold)

            // 說明
            Text("我們已發送驗證郵件到：")
                .foregroundStyle(.secondary)

            Text(authService.currentFirebaseUser?.email ?? "")
                .font(.headline)

            Text("請點擊郵件中的連結完成驗證，然後點擊下方按鈕繼續。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            // 已驗證按鈕
            Button {
                Task {
                    await checkVerification()
                }
            } label: {
                Text("我已驗證")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)

            // 重新發送按鈕
            Button {
                Task {
                    await resendEmail()
                }
            } label: {
                Text("重新發送驗證郵件")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }

            Spacer()

            // 登出按鈕
            Button {
                try? authService.signOut()
            } label: {
                Text("使用其他帳號")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)
        }
        .alert("提示", isPresented: $showAlert) {
            Button("確定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .disabled(authService.isLoading)
    }

    private func checkVerification() async {
        do {
            try await authService.reloadUser()

            if authService.authState != .signedIn {
                alertMessage = "郵件尚未驗證，請檢查您的信箱。"
                showAlert = true
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func resendEmail() async {
        do {
            try await authService.resendVerificationEmail()
            alertMessage = "驗證郵件已重新發送"
            showAlert = true
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

#Preview {
    LoginView()
}
