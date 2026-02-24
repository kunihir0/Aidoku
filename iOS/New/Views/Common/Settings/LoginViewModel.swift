//
//  LoginViewModel.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import SwiftUI
import AidokuRunner
import AuthenticationServices
import CommonCrypto

@MainActor
class LoginViewModel: ObservableObject {
    let source: AidokuRunner.Source?
    let setting: Setting
    let namespace: String?

    @Published var showLoginAlert = false
    @Published var showLogoutAlert = false
    @Published var showLoginFailAlert = false
    @Published var showLoginWebConfirm = false
    @Published var showLoginWebView = false

    @Published var loginCookies: [String: String] = [:]
    @Published var loginLocalStorage: [String: String] = [:]
    @Published var username = ""
    @Published var password = ""
    @Published var loginLoading = false
    @Published var loginReload = false

    // For OAuth
    private var session: ASWebAuthenticationSession?
    private static var loginShimController = LoginShimViewController()

    static let usernameKeySuffix = ".username"
    static let passwordKeySuffix = ".password"
    static let cookieKeysKeySuffix = ".keys"
    static let cookieValuesKeySuffix = ".values"
    static let localStoragePrefix = ".ls."

    init(source: AidokuRunner.Source?, setting: Setting, namespace: String?) {
        self.source = source
        self.setting = setting
        self.namespace = namespace
    }

    private func key(_ key: String) -> String {
        if let namespace {
            "\(namespace).\(key)"
        } else {
            key
        }
    }

    var settingKey: String {
        key(setting.key)
    }

    func loadCredentials() {
        username = SettingsStore.shared.get(key: settingKey + Self.usernameKeySuffix)
        password = SettingsStore.shared.get(key: settingKey + Self.passwordKeySuffix)
    }

    func handleBasicLogin(username: String, password: String) {
        guard !(username.isEmpty || password.isEmpty) else {
            return
        }

        func commit() {
            SettingsStore.shared.set(key: settingKey + Self.usernameKeySuffix, value: username)
            SettingsStore.shared.set(key: settingKey + Self.passwordKeySuffix, value: password)
            SettingsStore.shared.set(key: settingKey, value: "logged_in")
        }

        if let source, source.features.handlesBasicLogin {
            loginLoading = true
            Task {
                do {
                    let success = try await source.handleBasicLogin(key: setting.key, username: username, password: password)
                    if success {
                        commit()
                    } else {
                        showLoginFailAlert = true
                    }
                } catch {
                    LogManager.logger.error("Error handling basic login for \(source.key): \(error)")
                    showLoginFailAlert = true
                }
                loginLoading = false

                self.username = SettingsStore.shared.get(key: settingKey + Self.usernameKeySuffix)
                self.password = SettingsStore.shared.get(key: settingKey + Self.passwordKeySuffix)
            }
        } else {
            commit()
        }
    }

    func logout(value: LoginSetting) {
        SettingsStore.shared.remove(key: settingKey + Self.usernameKeySuffix)
        SettingsStore.shared.remove(key: settingKey + Self.passwordKeySuffix)
        SettingsStore.shared.remove(key: settingKey + Self.cookieKeysKeySuffix)
        SettingsStore.shared.remove(key: settingKey + Self.cookieValuesKeySuffix)

        if let localStorageKeys = value.localStorageKeys {
            for lsKey in localStorageKeys {
                SettingsStore.shared.remove(key: settingKey + Self.localStoragePrefix + lsKey)
            }
        }
        SettingsStore.shared.remove(key: settingKey)
        username = ""
        password = ""
    }

    func handleOAuthLogin(value: LoginSetting) {
        let url: URL?

        if let urlString = value.url {
            url = URL(string: urlString)
        } else if let urlKey = value.urlKey {
            url = URL(string: SettingsStore.shared.get(key: key(urlKey)))
        } else {
            url = nil
        }

        guard var url else {
            LogManager.logger.error("Invalid login URL: \(value.url ?? "missing")")
            return
        }

        var codeVerifier: String?
        var clientId: String?
        var redirectUri: String?

        if value.pkce ?? false {
            guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                LogManager.logger.error("Malformed URL: \(url)")
                return
            }
            codeVerifier = generateCodeVerifier()
            SettingsStore.shared.set(key: settingKey + ".codeVerifier", value: codeVerifier!)
            let codeChallenge = generateCodeChallenge(from: codeVerifier!)
            var queryItems = urlComponents.queryItems ?? []
            clientId = queryItems.first(where: { $0.name == "client_id" })?.value
            redirectUri = queryItems.first(where: { $0.name == "redirect_uri" })?.value
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
            queryItems.append(URLQueryItem(name: "response_type", value: "code"))
            urlComponents.queryItems = queryItems

            guard let pkceUrl = urlComponents.url else {
                LogManager.logger.error("Unable to create PKCE URL: \(urlComponents)")
                return
            }
            url = pkceUrl
        }

        session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: value.callbackScheme ?? "aidoku"
        ) { callback, error in
            guard let callback else {
                LogManager.logger.error("No callback URL received")
                return
            }

            Task { @MainActor in
                self.loginLoading = true
            }

            defer {
                Task { @MainActor in
                    self.loginLoading = false
                }
            }

            if value.pkce ?? false, let tokenUrlString = value.tokenUrl {
                guard
                    let codeVerifier,
                    let urlComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                    let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    LogManager.logger.error("Missing code verifier or code")
                    return
                }

                guard let tokenUrl = URL(string: tokenUrlString) else {
                    LogManager.logger.error("Invalid token URL: \(tokenUrlString)")
                    return
                }

                var request = URLRequest(url: tokenUrl)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

                var parameters: [String: String] = [
                    "grant_type": "authorization_code",
                    "code": code,
                    "code_verifier": codeVerifier
                ]
                if let redirectUri {
                    parameters["redirect_uri"] = redirectUri
                }
                if let clientId {
                    parameters["client_id"] = clientId
                }

                let bodyString = parameters.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
                request.httpBody = bodyString.data(using: .utf8)

                let task = URLSession.shared.dataTask(with: request) { data, _, error in
                    if let error {
                        LogManager.logger.error("Error requesting access token: \(error.localizedDescription)")
                        return
                    }

                    guard let data else {
                        LogManager.logger.error("No data received from access token request")
                        return
                    }

                    let result = String(decoding: data, as: Unicode.UTF8.self)

                    Task { @MainActor in
                        SettingsStore.shared.set(key: self.settingKey, value: result)
                    }
                }

                task.resume()
            } else {
                if let error {
                    LogManager.logger.error("Error during login: \(error.localizedDescription)")
                }
                Task { @MainActor in
                    SettingsStore.shared.set(key: self.settingKey, value: callback.absoluteString)
                }

                if let notification = self.setting.notification {
                    if let source = self.source {
                        Task {
                            do {
                                try await source.handleNotification(notification: notification)
                            } catch {
                                LogManager.logger.error("Error handling setting notification for \(source.key): \(error)")
                            }
                        }
                    }
                    NotificationCenter.default.post(name: NSNotification.Name(notification), object: nil)
                }
            }
        }

        guard let session else { return }

        session.presentationContextProvider = Self.loginShimController
        session.start()
    }

    private func generateCodeVerifier() -> String {
        let length = 128
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        var codeVerifier = ""
        for _ in 0..<length {
            codeVerifier.append(characters.randomElement()!)
        }
        return codeVerifier
    }

    private func generateCodeChallenge(from codeVerifier: String) -> String {
        guard let data = codeVerifier.data(using: .ascii) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        let hashData = Data(hash)
        return hashData.base64EncodedString(options: .endLineWithLineFeed)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Web Login
    func commitWebLogin(cookies: [String: String]) {
        let keys = Array(cookies.keys)
        let values = keys.map { cookies[$0]! }
        SettingsStore.shared.set(key: settingKey + Self.cookieKeysKeySuffix, value: keys)
        SettingsStore.shared.set(key: settingKey + Self.cookieValuesKeySuffix, value: values)

        if cookies.isEmpty {
            SettingsStore.shared.remove(key: settingKey)
        } else {
            SettingsStore.shared.set(key: settingKey, value: "logged_in")
        }
    }

    func saveLocalStorage(_ localStorage: [String: String]) {
        for (lsKey, lsValue) in localStorage {
            SettingsStore.shared.set(key: settingKey + Self.localStoragePrefix + lsKey, value: lsValue)
        }
    }
}
