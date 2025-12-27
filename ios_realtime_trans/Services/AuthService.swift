//
//  AuthService.swift
//  ios_realtime_trans
//
//  Firebase 認證服務層
//  支援 Email/Password、Google Sign-In 和 Apple Sign-In
//

import Foundation
import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import AuthenticationServices
import CryptoKit

// MARK: - Auth Error

enum AuthError: Error, LocalizedError {
    case notSignedIn
    case emailNotVerified
    case invalidEmail
    case weakPassword
    case emailAlreadyInUse
    case wrongPassword
    case userNotFound
    case networkError
    case googleSignInFailed
    case appleSignInFailed
    case firestoreError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "尚未登入"
        case .emailNotVerified:
            return "請先驗證您的電子郵件"
        case .invalidEmail:
            return "電子郵件格式不正確"
        case .weakPassword:
            return "密碼至少需要 6 個字元"
        case .emailAlreadyInUse:
            return "此電子郵件已被使用"
        case .wrongPassword:
            return "密碼錯誤"
        case .userNotFound:
            return "找不到此帳號"
        case .networkError:
            return "網路連線錯誤，請稍後再試"
        case .googleSignInFailed:
            return "Google 登入失敗"
        case .appleSignInFailed:
            return "Apple 登入失敗"
        case .firestoreError(let message):
            return "資料庫錯誤: \(message)"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - User Model

struct AppUser: Codable, Identifiable {
    var id: String { uid }
    let uid: String
    let email: String
    var displayName: String?
    var photoURL: String?
    var phoneNumber: String?
    var phoneVerified: Bool
    var deviceId: String?      // ⭐️ 設備 ID
    var isAnonymous: Bool      // ⭐️ 是否為匿名用戶
    var credits: Int
    var slowCredits: Int
    var hasClaimedStarterPack: Bool  // ⭐️ 是否已領取新手禮包
    var stats: UserStats
    var settings: UserSettings
    var createdAt: Date
    var lastLogin: Date

    struct UserStats: Codable {
        var totalSessions: Int
        var totalTokensUsed: Int
        var totalCost: Double

        init(totalSessions: Int = 0, totalTokensUsed: Int = 0, totalCost: Double = 0) {
            self.totalSessions = totalSessions
            self.totalTokensUsed = totalTokensUsed
            self.totalCost = totalCost
        }
    }

    struct UserSettings: Codable {
        var defaultSourceLang: String
        var defaultTargetLang: String
        var theme: String

        init(defaultSourceLang: String = "zh", defaultTargetLang: String = "en", theme: String = "light") {
            self.defaultSourceLang = defaultSourceLang
            self.defaultTargetLang = defaultTargetLang
            self.theme = theme
        }
    }

    /// 從 Firestore 文檔初始化
    init?(document: [String: Any], uid: String) {
        self.uid = uid
        // email 可以為空（匿名用戶）
        self.email = document["email"] as? String ?? ""
        self.displayName = document["displayName"] as? String
        self.photoURL = document["photoURL"] as? String
        self.phoneNumber = document["phoneNumber"] as? String
        self.phoneVerified = document["phoneVerified"] as? Bool ?? false
        self.deviceId = document["deviceId"] as? String
        self.isAnonymous = document["isAnonymous"] as? Bool ?? false
        self.credits = document["credits"] as? Int ?? 0
        self.slowCredits = document["slow_credits"] as? Int ?? 0
        self.hasClaimedStarterPack = document["hasClaimedStarterPack"] as? Bool ?? false

        // 解析 stats
        if let statsData = document["stats"] as? [String: Any] {
            self.stats = UserStats(
                totalSessions: statsData["totalSessions"] as? Int ?? 0,
                totalTokensUsed: statsData["totalTokensUsed"] as? Int ?? 0,
                totalCost: statsData["totalCost"] as? Double ?? 0
            )
        } else {
            self.stats = UserStats()
        }

        // 解析 settings
        if let settingsData = document["settings"] as? [String: Any] {
            self.settings = UserSettings(
                defaultSourceLang: settingsData["defaultSourceLang"] as? String ?? "zh",
                defaultTargetLang: settingsData["defaultTargetLang"] as? String ?? "en",
                theme: settingsData["theme"] as? String ?? "light"
            )
        } else {
            self.settings = UserSettings()
        }

        // 解析時間戳
        if let createdTimestamp = document["createdAt"] as? Timestamp {
            self.createdAt = createdTimestamp.dateValue()
        } else {
            self.createdAt = Date()
        }

        if let lastLoginTimestamp = document["lastLogin"] as? Timestamp {
            self.lastLogin = lastLoginTimestamp.dateValue()
        } else {
            self.lastLogin = Date()
        }
    }

    /// 從 Firebase User 初始化（新用戶）
    init(firebaseUser: User) {
        self.uid = firebaseUser.uid
        self.email = firebaseUser.email ?? ""
        self.displayName = firebaseUser.displayName
        self.photoURL = firebaseUser.photoURL?.absoluteString
        self.phoneNumber = firebaseUser.phoneNumber
        self.phoneVerified = false
        self.deviceId = nil
        self.isAnonymous = firebaseUser.isAnonymous
        self.credits = 0
        self.slowCredits = 0
        self.hasClaimedStarterPack = false
        self.stats = UserStats()
        self.settings = UserSettings()
        self.createdAt = Date()
        self.lastLogin = Date()
    }

    /// 設備用戶初始化（匿名用戶）
    init(uid: String, email: String, displayName: String?, deviceId: String?, isAnonymous: Bool, slowCredits: Int) {
        self.uid = uid
        self.email = email
        self.displayName = displayName
        self.photoURL = nil
        self.phoneNumber = nil
        self.phoneVerified = false
        self.deviceId = deviceId
        self.isAnonymous = isAnonymous
        self.credits = 0
        self.slowCredits = slowCredits
        self.hasClaimedStarterPack = false
        self.stats = UserStats()
        self.settings = UserSettings()
        self.createdAt = Date()
        self.lastLogin = Date()
    }

    /// 轉換為 Firestore 文檔
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "uid": uid,
            "email": email,
            "displayName": displayName as Any,
            "photoURL": photoURL as Any,
            "phoneNumber": phoneNumber as Any,
            "phoneVerified": phoneVerified,
            "isAnonymous": isAnonymous,
            "credits": credits,
            "slow_credits": slowCredits,
            "hasClaimedStarterPack": hasClaimedStarterPack,
            "stats": [
                "totalSessions": stats.totalSessions,
                "totalTokensUsed": stats.totalTokensUsed,
                "totalCost": stats.totalCost
            ],
            "settings": [
                "defaultSourceLang": settings.defaultSourceLang,
                "defaultTargetLang": settings.defaultTargetLang,
                "theme": settings.theme
            ],
            "createdAt": Timestamp(date: createdAt),
            "lastLogin": Timestamp(date: lastLogin),
            "updatedAt": Timestamp(date: Date())
        ]

        // 如果有設備 ID，加入文檔
        if let deviceId = deviceId {
            data["deviceId"] = deviceId
        }

        return data
    }
}

// MARK: - Auth Service

@Observable
final class AuthService {

    // MARK: - Singleton

    static let shared = AuthService()

    // MARK: - Published Properties

    /// 當前用戶（Firebase Auth）
    private(set) var currentFirebaseUser: User?

    /// 當前用戶（App Model）
    private(set) var currentUser: AppUser?

    /// 是否已登入
    var isSignedIn: Bool {
        currentFirebaseUser != nil
    }

    /// 是否已驗證郵件（Email 登入需要）
    var isEmailVerified: Bool {
        currentFirebaseUser?.isEmailVerified ?? false
    }

    /// 認證狀態
    enum AuthState: Equatable {
        case unknown       // 初始狀態
        case signedOut     // 已登出
        case signedIn      // 已登入
        case emailNotVerified  // 已註冊但未驗證郵件
    }

    private(set) var authState: AuthState = .unknown

    /// 是否正在載入
    private(set) var isLoading: Bool = false

    /// 錯誤訊息
    private(set) var errorMessage: String?

    // MARK: - Private Properties

    private let auth = Auth.auth()
    private let db: Firestore
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    // MARK: - Initialization

    private init() {
        // 初始化 Firestore（使用指定的 named database）
        // ⭐️ 使用 realtime-voice-database（與 web app 共用）
        db = Firestore.firestore(database: "realtime-voice-database")

        setupAuthStateListener()
    }

    deinit {
        if let handle = authStateHandle {
            auth.removeStateDidChangeListener(handle)
        }
    }

    // MARK: - Auth State Listener

    private func setupAuthStateListener() {
        print("🔐 [Auth] setupAuthStateListener 開始")

        authStateHandle = auth.addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }

            print("🔐 [Auth] 狀態變化: user = \(user?.email ?? "nil")")

            // ⭐️ 確保在主線程更新 UI 狀態
            DispatchQueue.main.async {
                self.currentFirebaseUser = user

                if let user = user {
                    let isThirdParty = self.isThirdPartySignIn(user)
                    let isVerified = user.isEmailVerified
                    print("🔐 [Auth] 用戶已登入: email=\(user.email ?? "nil"), isThirdParty=\(isThirdParty), isVerified=\(isVerified)")

                    // 用戶已登入（第三方登入或已驗證的 Email）
                    if isVerified || isThirdParty {
                        print("🔐 [Auth] 設定 authState = .signedIn")
                        self.authState = .signedIn
                        // 載入或創建用戶資料
                        Task {
                            await self.loadOrCreateUserData(firebaseUser: user)
                        }
                    } else {
                        // Email 未驗證
                        print("🔐 [Auth] 設定 authState = .emailNotVerified")
                        self.authState = .emailNotVerified
                        self.currentUser = nil
                    }
                } else {
                    // 用戶已登出
                    print("🔐 [Auth] 設定 authState = .signedOut")
                    self.authState = .signedOut
                    self.currentUser = nil
                }
            }
        }
    }

    /// 判斷是否為 Google 登入
    private func isGoogleSignIn(_ user: User) -> Bool {
        return user.providerData.contains { $0.providerID == "google.com" }
    }

    /// 判斷是否為 Apple 登入
    private func isAppleSignIn(_ user: User) -> Bool {
        return user.providerData.contains { $0.providerID == "apple.com" }
    }

    /// 判斷是否為第三方登入（Google 或 Apple）
    private func isThirdPartySignIn(_ user: User) -> Bool {
        return isGoogleSignIn(user) || isAppleSignIn(user)
    }

    // MARK: - Email/Password Authentication

    /// 註冊新帳號
    @MainActor
    func signUp(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let result = try await auth.createUser(withEmail: email, password: password)

            // 發送驗證郵件
            try await result.user.sendEmailVerification()

            print("✅ [Auth] 註冊成功，已發送驗證郵件到: \(email)")

            // 創建用戶文檔（但標記為未驗證）
            let newUser = AppUser(firebaseUser: result.user)
            try await createUserDocument(user: newUser)

            // 設置狀態為未驗證
            authState = .emailNotVerified

        } catch let error as NSError {
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    /// Email/Password 登入
    @MainActor
    func signIn(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let result = try await auth.signIn(withEmail: email, password: password)

            // 檢查郵件是否已驗證
            if !result.user.isEmailVerified {
                authState = .emailNotVerified
                throw AuthError.emailNotVerified
            }

            print("✅ [Auth] Email 登入成功: \(email)")

            // 更新最後登入時間
            await updateLastLogin(uid: result.user.uid)

        } catch let error as NSError {
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    /// 重新發送驗證郵件
    @MainActor
    func resendVerificationEmail() async throws {
        guard let user = currentFirebaseUser else {
            throw AuthError.notSignedIn
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await user.sendEmailVerification()
            print("✅ [Auth] 已重新發送驗證郵件")
        } catch let error as NSError {
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    /// 重新載入用戶資料（檢查郵件驗證狀態）
    @MainActor
    func reloadUser() async throws {
        guard let user = currentFirebaseUser else {
            throw AuthError.notSignedIn
        }

        try await user.reload()

        if user.isEmailVerified {
            authState = .signedIn
            await loadOrCreateUserData(firebaseUser: user)
        }
    }

    /// 忘記密碼
    @MainActor
    func sendPasswordReset(email: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await auth.sendPasswordReset(withEmail: email)
            print("✅ [Auth] 已發送密碼重設郵件到: \(email)")
        } catch let error as NSError {
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    // MARK: - Google Sign-In

    /// Google 登入
    @MainActor
    func signInWithGoogle() async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        // 獲取 root view controller
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw AuthError.googleSignInFailed
        }

        do {
            // 執行 Google Sign-In
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)

            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthError.googleSignInFailed
            }

            let accessToken = result.user.accessToken.tokenString

            // 創建 Firebase credential
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: accessToken
            )

            // Firebase 登入
            let authResult = try await auth.signIn(with: credential)

            print("✅ [Auth] Google 登入成功: \(authResult.user.email ?? "unknown")")

            // 更新最後登入時間
            await updateLastLogin(uid: authResult.user.uid)

        } catch let error as GIDSignInError {
            if error.code == .canceled {
                print("ℹ️ [Auth] 用戶取消 Google 登入")
                return  // 用戶取消，不算錯誤
            }
            errorMessage = "Google 登入失敗: \(error.localizedDescription)"
            throw AuthError.googleSignInFailed
        } catch let error as NSError {
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    // MARK: - Apple Sign-In

    /// 當前 Apple Sign-In 的 nonce（用於驗證）
    private var currentNonce: String?

    /// 生成隨機 nonce
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }
        return String(nonce)
    }

    /// SHA256 哈希
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap {
            String(format: "%02x", $0)
        }.joined()
        return hashString
    }

    /// 開始 Apple Sign-In 流程
    /// - Returns: ASAuthorizationAppleIDRequest 配置 和 哈希過的 nonce
    func startAppleSignIn() -> (request: ASAuthorizationAppleIDRequest, hashedNonce: String) {
        let nonce = randomNonceString()
        currentNonce = nonce
        let hashedNonce = sha256(nonce)

        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce

        return (request, hashedNonce)
    }

    /// 完成 Apple Sign-In
    /// - Parameters:
    ///   - authorization: Apple 授權結果
    @MainActor
    func completeAppleSignIn(authorization: ASAuthorization) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AuthError.appleSignInFailed
        }

        guard let nonce = currentNonce else {
            print("❌ [Auth] Apple Sign-In: Invalid state - nonce is nil")
            throw AuthError.appleSignInFailed
        }

        guard let appleIDToken = appleIDCredential.identityToken else {
            print("❌ [Auth] Apple Sign-In: Unable to fetch identity token")
            throw AuthError.appleSignInFailed
        }

        guard let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            print("❌ [Auth] Apple Sign-In: Unable to serialize token string")
            throw AuthError.appleSignInFailed
        }

        // 創建 Firebase credential
        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )

        do {
            print("🍎 [Auth] Apple Sign-In: 開始 Firebase 登入...")
            print("🍎 [Auth] Apple Sign-In: nonce = \(nonce.prefix(10))...")

            // Firebase 登入
            let authResult = try await auth.signIn(with: credential)

            // ⭐️ Apple 首次登入時可能提供名字，需要更新到 Firebase
            if let fullName = appleIDCredential.fullName {
                let displayName = [fullName.givenName, fullName.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")

                if !displayName.isEmpty {
                    let changeRequest = authResult.user.createProfileChangeRequest()
                    changeRequest.displayName = displayName
                    try? await changeRequest.commitChanges()
                    print("✅ [Auth] Apple 用戶名稱已更新: \(displayName)")
                }
            }

            print("✅ [Auth] Apple 登入成功: \(authResult.user.email ?? "unknown")")

            // 更新最後登入時間
            await updateLastLogin(uid: authResult.user.uid)

            // 清除 nonce
            currentNonce = nil

        } catch let error as NSError {
            print("❌ [Auth] Apple Sign-In Firebase 錯誤: code=\(error.code), domain=\(error.domain)")
            print("❌ [Auth] Apple Sign-In 詳細錯誤: \(error.localizedDescription)")
            print("❌ [Auth] Apple Sign-In userInfo: \(error.userInfo)")
            currentNonce = nil
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    /// 處理 Apple Sign-In 錯誤
    @MainActor
    func handleAppleSignInError(_ error: Error) {
        isLoading = false
        currentNonce = nil

        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                print("ℹ️ [Auth] 用戶取消 Apple 登入")
                return  // 用戶取消，不算錯誤
            case .invalidResponse:
                errorMessage = "Apple 登入回應無效"
            case .notHandled:
                errorMessage = "Apple 登入未處理"
            case .failed:
                errorMessage = "Apple 登入失敗"
            case .notInteractive:
                errorMessage = "Apple 登入需要互動"
            case .unknown:
                errorMessage = "Apple 登入發生未知錯誤"
            @unknown default:
                errorMessage = "Apple 登入錯誤: \(authError.localizedDescription)"
            }
        } else {
            errorMessage = "Apple 登入錯誤: \(error.localizedDescription)"
        }

        print("❌ [Auth] Apple Sign-In 錯誤: \(errorMessage ?? "unknown")")
    }

    // MARK: - Sign Out

    /// 登出
    @MainActor
    func signOut() throws {
        do {
            try auth.signOut()
            GIDSignIn.sharedInstance.signOut()

            currentUser = nil
            authState = .signedOut

            print("✅ [Auth] 已登出")
        } catch {
            errorMessage = "登出失敗: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Device ID Anonymous Sign-In

    /// 新用戶初始額度
    private let initialSlowCredits: Int = 15000

    /// 獲取設備 ID (IDFV)
    private func getDeviceId() -> String? {
        return UIDevice.current.identifierForVendor?.uuidString
    }

    /// 使用設備 ID 自動登入/註冊
    /// - 如果設備已註冊，直接載入用戶資料
    /// - 如果是新設備，創建匿名帳號並給予 15000 額度
    @MainActor
    func signInWithDeviceId() async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        guard let deviceId = getDeviceId() else {
            print("❌ [Auth] 無法獲取設備 ID")
            throw AuthError.unknown("無法獲取設備識別碼")
        }

        print("📱 [Auth] 設備 ID: \(deviceId)")

        do {
            // ⭐️ 步驟 1: 先匿名登入（這樣才有權限查詢 Firestore）
            var currentUserId: String

            if let existingUser = auth.currentUser {
                // 已有登入用戶，直接使用
                currentUserId = existingUser.uid
                print("📱 [Auth] 已有 Firebase 用戶: \(currentUserId)")
            } else {
                // 匿名登入
                print("📱 [Auth] 執行匿名登入...")
                let authResult = try await auth.signInAnonymously()
                currentUserId = authResult.user.uid
                print("📱 [Auth] 匿名登入成功: \(currentUserId)")
            }

            // ⭐️ 步驟 2: 查詢此設備 ID 是否已存在於資料庫
            let existingUserId = try await findUserByDeviceId(deviceId)

            if let existingUserId = existingUserId {
                // ⭐️ 設備已註冊
                print("📱 [Auth] 設備已註冊，用戶 ID: \(existingUserId)")

                if currentUserId == existingUserId {
                    // 同一個用戶，直接載入資料
                    await loadExistingUserData(uid: existingUserId)
                } else {
                    // 不同用戶（新匿名帳號），載入已存在的用戶資料
                    // 注意：這裡我們選擇載入設備對應的舊帳號資料
                    await loadExistingUserData(uid: existingUserId)
                }

                print("✅ [Auth] 設備用戶已載入")
            } else {
                // ⭐️ 新設備，檢查是否已有此用戶的文檔
                let userDoc = try await db.collection("users").document(currentUserId).getDocument()

                if userDoc.exists {
                    // 用戶文檔已存在但沒有 deviceId，更新它
                    print("📱 [Auth] 用戶已存在，更新 deviceId")
                    try await db.collection("users").document(currentUserId).updateData([
                        "deviceId": deviceId,
                        "updatedAt": FieldValue.serverTimestamp()
                    ])
                    await loadExistingUserData(uid: currentUserId)
                } else {
                    // 全新用戶，創建文檔（含設備 ID 和初始額度）
                    print("📱 [Auth] 新設備，創建用戶文檔")
                    try await createDeviceUserDocument(
                        uid: currentUserId,
                        deviceId: deviceId
                    )
                }

                print("✅ [Auth] 設備匿名登入成功，已給予 \(initialSlowCredits) 額度")
            }

        } catch let error as NSError {
            let authError = mapFirebaseError(error)
            errorMessage = authError.localizedDescription
            throw authError
        }
    }

    /// 根據設備 ID 查找已存在的用戶
    private func findUserByDeviceId(_ deviceId: String) async throws -> String? {
        let query = db.collection("users")
            .whereField("deviceId", isEqualTo: deviceId)
            .limit(to: 1)

        let snapshot = try await query.getDocuments()

        if let document = snapshot.documents.first {
            return document.documentID
        }
        return nil
    }

    /// 為設備用戶創建文檔（含初始額度）
    private func createDeviceUserDocument(uid: String, deviceId: String) async throws {
        let now = Date()

        let userData: [String: Any] = [
            "uid": uid,
            "email": "",  // 匿名用戶無 email
            "displayName": "設備用戶",
            "photoURL": NSNull(),
            "phoneNumber": NSNull(),
            "phoneVerified": false,
            "deviceId": deviceId,  // ⭐️ 存儲設備 ID
            "isAnonymous": true,   // ⭐️ 標記為匿名用戶
            "credits": 0,
            "slow_credits": initialSlowCredits,  // ⭐️ 新用戶給予 15000 額度
            "stats": [
                "totalSessions": 0,
                "totalTokensUsed": 0,
                "totalCost": 0.0
            ],
            "settings": [
                "defaultSourceLang": "zh",
                "defaultTargetLang": "en",
                "theme": "light"
            ],
            "createdAt": Timestamp(date: now),
            "lastLogin": Timestamp(date: now),
            "updatedAt": Timestamp(date: now)
        ]

        let docRef = db.collection("users").document(uid)
        try await docRef.setData(userData)

        // 更新本地用戶狀態
        let newUser = AppUser(
            uid: uid,
            email: "",
            displayName: "設備用戶",
            deviceId: deviceId,
            isAnonymous: true,
            slowCredits: initialSlowCredits
        )

        await MainActor.run {
            self.currentUser = newUser
            self.authState = .signedIn
        }

        print("✅ [Auth] 創建設備用戶: \(uid), 額度: \(initialSlowCredits)")
    }

    /// 載入已存在的用戶資料（根據 uid）
    private func loadExistingUserData(uid: String) async {
        do {
            let docRef = db.collection("users").document(uid)
            let document = try await docRef.getDocument()

            if document.exists, let data = document.data() {
                if let user = AppUser(document: data, uid: uid) {
                    await MainActor.run {
                        self.currentUser = user
                        self.authState = .signedIn
                    }
                    print("✅ [Auth] 載入已存在用戶: \(user.email), slowCredits = \(user.slowCredits)")
                }
            }
        } catch {
            print("❌ [Auth] 載入用戶資料失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Firestore User Data

    /// 載入或創建用戶資料
    private func loadOrCreateUserData(firebaseUser: User) async {
        let uid = firebaseUser.uid

        do {
            let docRef = db.collection("users").document(uid)
            let document = try await docRef.getDocument()

            if document.exists, let data = document.data() {
                // 用戶已存在，載入資料
                print("📊 [Auth] Firestore 原始資料: slow_credits = \(data["slow_credits"] ?? "nil")")
                if let user = AppUser(document: data, uid: uid) {
                    await MainActor.run {
                        self.currentUser = user
                    }
                    print("✅ [Auth] 載入用戶資料: \(user.email), slowCredits = \(user.slowCredits)")
                }
            } else {
                // 新用戶，創建文檔
                let newUser = AppUser(firebaseUser: firebaseUser)
                try await createUserDocument(user: newUser)

                await MainActor.run {
                    self.currentUser = newUser
                }
                print("✅ [Auth] 創建新用戶: \(newUser.email)")
            }
        } catch {
            print("❌ [Auth] 載入用戶資料失敗: \(error.localizedDescription)")
        }
    }

    /// 創建用戶文檔
    private func createUserDocument(user: AppUser) async throws {
        let docRef = db.collection("users").document(user.uid)
        try await docRef.setData(user.toFirestoreData())
    }

    /// 更新最後登入時間
    private func updateLastLogin(uid: String) async {
        let docRef = db.collection("users").document(uid)

        do {
            try await docRef.updateData([
                "lastLogin": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            print("⚠️ [Auth] 更新登入時間失敗: \(error.localizedDescription)")
        }
    }

    /// 更新用戶設定
    @MainActor
    func updateUserSettings(sourceLang: String? = nil, targetLang: String? = nil) async throws {
        guard let user = currentUser else {
            throw AuthError.notSignedIn
        }

        var updates: [String: Any] = [
            "updatedAt": Timestamp(date: Date())
        ]

        if let sourceLang = sourceLang {
            updates["settings.defaultSourceLang"] = sourceLang
        }

        if let targetLang = targetLang {
            updates["settings.defaultTargetLang"] = targetLang
        }

        let docRef = db.collection("users").document(user.uid)
        try await docRef.updateData(updates)

        // 更新本地資料
        var updatedUser = user
        if let sourceLang = sourceLang {
            updatedUser.settings.defaultSourceLang = sourceLang
        }
        if let targetLang = targetLang {
            updatedUser.settings.defaultTargetLang = targetLang
        }
        self.currentUser = updatedUser
    }

    // MARK: - 額度管理

    /// 扣除用戶額度
    /// - Parameter credits: 要扣除的額度數
    @MainActor
    func deductCredits(_ credits: Int) async throws {
        guard var user = currentUser else {
            throw AuthError.notSignedIn
        }

        guard credits > 0 else { return }

        let newCredits = max(0, user.slowCredits - credits)

        // 更新 Firestore
        let docRef = db.collection("users").document(user.uid)
        try await docRef.updateData([
            "slow_credits": newCredits,
            "updatedAt": FieldValue.serverTimestamp()
        ])

        // 更新本地資料
        user.slowCredits = newCredits
        self.currentUser = user

        print("💰 [Auth] 已扣除 \(credits) 額度，剩餘: \(newCredits)")
    }

    /// 增加用戶額度（購買後調用）
    /// - Parameter credits: 要增加的額度數
    @MainActor
    func addCredits(_ credits: Int) async throws {
        guard var user = currentUser else {
            throw AuthError.notSignedIn
        }

        guard credits > 0 else { return }

        let newCredits = user.slowCredits + credits

        // 更新 Firestore
        let docRef = db.collection("users").document(user.uid)
        try await docRef.updateData([
            "slow_credits": newCredits,
            "updatedAt": FieldValue.serverTimestamp()
        ])

        // 更新本地資料
        user.slowCredits = newCredits
        self.currentUser = user

        print("💰 [Auth] 已增加 \(credits) 額度，目前: \(newCredits)")
    }

    /// 標記新手禮包已領取
    @MainActor
    func markStarterPackClaimed() async throws {
        guard var user = currentUser else {
            throw AuthError.notSignedIn
        }

        // 更新 Firestore
        let docRef = db.collection("users").document(user.uid)
        try await docRef.updateData([
            "hasClaimedStarterPack": true,
            "updatedAt": FieldValue.serverTimestamp()
        ])

        // 更新本地資料
        user.hasClaimedStarterPack = true
        self.currentUser = user

        print("🎁 [Auth] 新手禮包已標記為已領取")
    }

    /// 檢查用戶是否有足夠額度
    /// - Parameter required: 所需額度
    /// - Returns: 是否有足夠額度
    func hasEnoughCredits(_ required: Int = 100) -> Bool {
        guard let user = currentUser else { return false }
        return user.slowCredits >= required
    }

    /// 刷新用戶額度（從 Firestore 重新載入）
    @MainActor
    func refreshCredits() async {
        guard let uid = currentUser?.uid else { return }

        do {
            let docRef = db.collection("users").document(uid)
            let document = try await docRef.getDocument()

            if let data = document.data(),
               let slowCredits = data["slow_credits"] as? Int {
                var user = currentUser
                user?.slowCredits = slowCredits
                if let updatedUser = user {
                    self.currentUser = updatedUser
                    print("💰 [Auth] 刷新額度: \(slowCredits)")
                }
            }
        } catch {
            print("⚠️ [Auth] 刷新額度失敗: \(error.localizedDescription)")
        }
    }

    /// ⭐️ 更新本地用戶資料（用於樂觀更新，不寫入 Firestore）
    /// - Parameter user: 更新後的用戶資料
    @MainActor
    func updateLocalUser(_ user: AppUser) {
        self.currentUser = user
    }

    // MARK: - Error Mapping

    private func mapFirebaseError(_ error: NSError) -> AuthError {
        guard let errorCode = AuthErrorCode(rawValue: error.code) else {
            return .unknown(error.localizedDescription)
        }

        switch errorCode {
        case .invalidEmail:
            return .invalidEmail
        case .weakPassword:
            return .weakPassword
        case .emailAlreadyInUse:
            return .emailAlreadyInUse
        case .wrongPassword:
            return .wrongPassword
        case .userNotFound:
            return .userNotFound
        case .networkError:
            return .networkError
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
