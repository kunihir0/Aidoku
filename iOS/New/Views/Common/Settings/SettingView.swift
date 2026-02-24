//
//  SettingView.swift
//  Aidoku
//
//  Created by Skitty on 3/25/24.
//

import AidokuRunner
import AuthenticationServices
import LocalAuthentication
import SafariServices
import SwiftUI

/// View for a given AidokuRunner Setting.
struct SettingView: View {
    let source: AidokuRunner.Source?
    let setting: Setting
    var namespace: String?
    var onChange: ((String) -> Void)?

    @Binding var hidden: Bool

    @Environment(\.settingPageContent) private var pageContentHandler
    @Environment(\.settingCustomContent) private var customContentHandler

    @Binding private var stringListBinding: [String]
    @Binding private var doubleBinding: Double

    @State private var requires: Bool
    @State private var requiresFalse: Bool
    @State private var toggleValue: Bool

    @State private var valueChangeTask: Task<Void, Never>?
    @State private var showButtonConfirm = false
    @State private var showSafari = false
    @State private var skippedFirst = false
    @State private var pageIsActive = false

    @StateObject private var userDefaultsObserver: UserDefaultsObserver // causes view to refresh when setting changes (e.g. when resetting)
    @StateObject private var requiresObserver: UserDefaultsObserver
    @StateObject private var loginViewModel: LoginViewModel

    @FocusState private var fieldFocused: Bool

    init(
        source: AidokuRunner.Source? = nil,
        setting: Setting,
        namespace: String? = nil,
        hidden: Binding<Bool> = .constant(false),
        onChange: ((String) -> Void)? = nil
    ) {
        self.source = source

        // localize the setting title
        // used because the language setting comes from the AidokuRunner package, where it can't be localized
        var setting = setting
        setting.title = NSLocalizedString(setting.title)

        self.setting = setting
        self.namespace = namespace
        self.onChange = onChange
        self._hidden = hidden

        // need to use this before all properties are initialized
        func key(_ key: String) -> String {
            if key.isEmpty {
                key
            } else if let namespace {
                "\(namespace).\(key)"
            } else {
                key
            }
        }

        _userDefaultsObserver = StateObject(wrappedValue: UserDefaultsObserver(key: key(setting.key)))
        _loginViewModel = StateObject(wrappedValue: LoginViewModel(source: source, setting: setting, namespace: namespace))

        var keys: [String] = []
        if let requires = setting.requires {
            let key = key(requires)
            _requires = State(initialValue: SettingsStore.shared.get(key: key))
            keys.append(key)
        } else {
            _requires = State(initialValue: true)
        }
        if let requiresFalse = setting.requiresFalse {
            let key = key(requiresFalse)
            _requiresFalse = State(initialValue: SettingsStore.shared.get(key: key))
            keys.append(key)
        } else {
            _requiresFalse = State(initialValue: false)
        }
        _requiresObserver = StateObject(wrappedValue: UserDefaultsObserver(keys: keys))

        switch setting.value {
            case .select:
                let key = key(setting.key)
                _stringListBinding = Binding(
                    get: { [SettingsStore.shared.get(key: key)] },
                    set: { SettingsStore.shared.set(key: key, value: $0.first!) }
                )
                _doubleBinding = Binding.constant(0)
            case .multiselect:
                _stringListBinding = SettingsStore.shared.binding(key: key(setting.key))
                _doubleBinding = Binding.constant(0)
            case .editableList:
                _stringListBinding = SettingsStore.shared.binding(key: key(setting.key))
                _doubleBinding = Binding.constant(0)
            case .stepper:
                _stringListBinding = Binding.constant([])
                _doubleBinding = SettingsStore.shared.binding(key: key(setting.key))
            default:
                _stringListBinding = Binding.constant([])
                _doubleBinding = Binding.constant(0)
        }
        if case .toggle = setting.value {
            _toggleValue = State(initialValue: SettingsStore.shared.get(key: key(setting.key)))
        } else {
            _toggleValue = State(initialValue: false)
        }
    }

    var body: some View {
        content
            .id(setting.type.requiresKey ? key(setting.key) : String(setting.hashValue))
            .onReceive(userDefaultsObserver.$observedValues) { _ in
                // skip the initial value load
                if !skippedFirst {
                    skippedFirst = true
                    return
                }
                handleValueChange()
            }
            .onReceive(requiresObserver.$observedValues) { _ in
                if let requires = setting.requires {
                    let value = UserDefaults.standard.string(forKey: key(requires))
                    self.requires = value != nil && value != "0"
                }
                if let requiresFalse = setting.requiresFalse {
                    let value = UserDefaults.standard.string(forKey: key(requiresFalse))
                    self.requiresFalse = value != nil && value != "0"
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch setting.value {
            case let .group(value):
                groupView(value: value)
            case let .select(value):
                selectView(value: value)
            case let .multiselect(value):
                multiSelectView(value: value)
            case let .toggle(value):
                toggleView(value: value)
            case let .stepper(value):
                stepperView(value: value)
            case let .segment(value):
                segmentView(value: value)
            case let .text(value):
                textView(value: value)
            case let .button(value):
                buttonView(value: value)
            case let .link(value):
                linkView(value: value)
            case let .login(value):
                loginView(value: value)
            case let .page(value):
                pageView(value: value)
            case let .editableList(value):
                editableListView(value: value)
            case .custom:
                customView()
        }
    }

    /// Returns a settings key with the valid namespace
    private func key(_ key: String) -> String {
        if let namespace {
            "\(namespace).\(key)"
        } else {
            key
        }
    }

    private func handleValueChange() {
        onChange?(key(setting.key))

        valueChangeTask?.cancel()
        valueChangeTask = Task {
            // debounce change notification(s) with 500ms delay
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }

            func refresh() {
                for refresh in setting.refreshes {
                    NotificationCenter.default.post(name: Notification.Name("refresh-\(refresh)"), object: nil)
                }
            }
            if let source, let notification = setting.notification {
                do {
                    try await source.handleNotification(notification: notification)
                } catch {
                    LogManager.logger.error("Error handling setting notification for \(source.key): \(error)")
                }
            }
            refresh()

            let value: Any? = switch setting.value {
                case .select: stringListBinding.first
                case .multiselect: stringListBinding
                case .toggle: toggleValue
                case .stepper: doubleBinding
                case .segment: SettingsStore.shared.get(key: key(setting.key)) as Int
                case .editableList: stringListBinding
                default: nil
            }
            let notificationName = setting.notification ?? key(setting.key)
            NotificationCenter.default.post(name: .init(notificationName), object: value)
        }
    }

    private func auth() async -> Bool {
        let context = LAContext()
        let success: Bool

        do {
            success = try await context.evaluatePolicy(
                .defaultPolicy,
                localizedReason: NSLocalizedString("AUTH_TO_OPEN")
            )
        } catch {
            // The error is to be displayed to users, so we can ignore it.
            return false
        }

        return success
    }

    private var disabled: Bool {
        !requires || requiresFalse
    }

    private let disabledOpacity: CGFloat = 0.5
}

// MARK: Group View
extension SettingView {
    @ViewBuilder
    func groupView(value: GroupSetting) -> some View {
        if !disabled {
            let body = ForEach(value.items.indices, id: \.self) { offset in
                let setting = value.items[offset]
                SettingView(source: source, setting: setting, namespace: namespace, onChange: onChange)
                    .tag(setting.key.isEmpty ? UUID().uuidString : key(setting.key))
            }
            if let footer = value.footer.flatMap({ NSLocalizedString($0) }) {
                if !setting.title.isEmpty {
                    Section {
                        body
                    } header: {
                        Text(setting.title)
                    } footer: {
                        Text(footer)
                    }
                } else {
                    Section {
                        body
                    } footer: {
                        Text(footer)
                    }
                }
            } else if !setting.title.isEmpty {
                Section(setting.title) {
                    body
                }
            } else {
                Section {
                    body
                }
            }
        }
    }
}

// MARK: Select View
extension SettingView {
    @ViewBuilder
    func selectView(value: SelectSetting) -> some View {
        Button {
            if value.authToOpen ?? false {
                Task {
                    let success = await auth()
                    if success {
                        pageIsActive = true
                    }
                }
            } else {
                pageIsActive = true
            }
        } label: {
            NavigationLink(
                destination: SelectDestination(
                    setting: setting,
                    value: value,
                    key: key(setting.key),
                    stringListBinding: $stringListBinding
                )
                .environment(\.settingPageContent, pageContentHandler),
                isActive: $pageIsActive
            ) {
                HStack {
                    Text(setting.title)
                        .lineLimit(1)
                    Spacer()
                    if let item = stringListBinding.first {
                        let title = value.values
                            .firstIndex { $0 == item }
                            .flatMap { value.titles?[safe: $0] }
                        Text(title ?? item)
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                    }
                }
            }
            .environment(\.isEnabled, true) // remove double disabled effect
        }
        .foregroundStyle(.primary)
        .disabled(disabled)
        .opacity({
            if #available(iOS 26.0, *) {
                1 // ios 26 has the correct disabled style
            } else {
                disabled ? disabledOpacity : 1
            }
        }())
    }

    private struct SelectDestination: View {
        let setting: Setting
        let value: SelectSetting
        let key: String

        @Binding var stringListBinding: [String]

        @Environment(\.settingPageContent) private var pageContentHandler

        var body: some View {
            Group {
                if let content = pageContentHandler?(setting.key) {
                    content
                } else {
                    List {
                        ForEach(value.values.indices, id: \.self) { offset in
                            let item = value.values[offset]
                            let selected = stringListBinding.contains(item)
                            Button {
                                stringListBinding = [item]
                            } label: {
                                HStack {
                                    Text(value.titles?[safe: offset] ?? item)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .onChange(of: stringListBinding) { _ in
                        if let item = stringListBinding.first {
                            SettingsStore.shared.set(key: key, value: item)
                        }
                    }
                }
            }
            .navigationTitle(setting.title)
        }
    }
}

extension SettingView {
    @ViewBuilder
    func multiSelectView(value: MultiSelectSetting) -> some View {
        Button {
            if value.authToOpen ?? false {
                Task {
                    let success = await auth()
                    if success {
                        pageIsActive = true
                    }
                }
            } else {
                pageIsActive = true
            }
        } label: {
            NavigationLink(
                setting.title,
                destination: MultiSelectDestination(
                    setting: setting,
                    value: value,
                    key: key(setting.key),
                    stringListBinding: $stringListBinding
                )
                .environment(\.settingPageContent, pageContentHandler),
                isActive: $pageIsActive
            )
            .environment(\.isEnabled, true) // remove double disabled effect
            .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .disabled(disabled)
        .opacity({
            if #available(iOS 26.0, *) {
                1
            } else {
                disabled ? disabledOpacity : 1
            }
        }())
    }

    private struct MultiSelectDestination: View {
        let setting: Setting
        let value: MultiSelectSetting
        let key: String

        @Binding var stringListBinding: [String]

        @Environment(\.settingPageContent) private var pageContentHandler

        var body: some View {
            Group {
                if let content = pageContentHandler?(setting.key) {
                    content
                } else {
                    List {
                        ForEach(value.values.indices, id: \.self) { offset in
                            let item = value.values[offset]
                            let selected = stringListBinding.contains(item)
                            Button {
                                if !selected {
                                    stringListBinding.append(item)
                                } else {
                                    stringListBinding.removeAll { $0 == item }
                                }
                            } label: {
                                HStack {
                                    Text(value.titles?[safe: offset] ?? item)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .onChange(of: stringListBinding) { _ in
                        SettingsStore.shared.set(key: key, value: stringListBinding)
                    }
                }
            }
            .navigationTitle(setting.title)
        }
    }
}

// MARK: Toggle View
extension (SettingView) {
    @ViewBuilder
    func toggleView(value: ToggleSetting) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(setting.title)
                    .lineLimit(1)
                if let subtitle = value.subtitle {
                    Text(NSLocalizedString(subtitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(disabled ? disabledOpacity : 1)
            .padding(.vertical, {
                if #available(iOS 26.0, *) {
                    0
                } else if value.subtitle != nil {
                    2
                } else {
                    0
                }
            }())

            Spacer()

            Toggle(isOn: $toggleValue) {
                EmptyView()
            }
            .labelsHidden()
            .onChange(of: toggleValue) { _ in
                if (value.authToDisable ?? false) && !toggleValue {
                    Task {
                        let success = await auth()
                        if success {
                            SettingsStore.shared.set(key: key(setting.key), value: false)
                        } else {
                            toggleValue = true
                        }
                    }
                } else {
                    SettingsStore.shared.set(key: key(setting.key), value: toggleValue)
                }
            }
        }
        .disabled(disabled)
    }
}

// MARK: Stepper View
extension SettingView {
    @ViewBuilder
    func stepperView(value: StepperSetting) -> some View {
        HStack {
            Text(setting.title)
                .lineLimit(1)
            Spacer()
            if value.maximumValue >= value.minimumValue {
                Text(String(format: "%g", doubleBinding))
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
                Stepper(
                    "",
                    value: $doubleBinding,
                    in: value.minimumValue...value.maximumValue,
                    step: value.stepValue ?? 1
                )
                .labelsHidden()
            } else {
                Text("Error: Invalid stepper range")
            }
        }
        .opacity(disabled ? disabledOpacity : 1)
        .disabled(disabled)
        .transition(.opacity)
    }
}

// MARK: Segment View
extension SettingView {
    @ViewBuilder
    func segmentView(value: SegmentSetting) -> some View {
        HStack {
            Text(setting.title)
                .opacity(disabled ? disabledOpacity : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Spacer()
            Picker("", selection: SettingsStore.shared.binding(key: key(setting.key)) as Binding<Int>) {
                ForEach(value.options.indices, id: \.self) { offset in
                    Text(value.options[offset])
                        .tag(offset)
                }
            }
            .pickerStyle(.segmented)
        }
        .disabled(disabled)
    }
}

// MARK: Text View
extension SettingView {
    @ViewBuilder
    func textView(value: TextSetting) -> some View {
        let autocapitalizationType: TextInputAutocapitalization? = value.autocapitalizationType.flatMap {
            switch UITextAutocapitalizationType(rawValue: $0) ?? .sentences {
                case .none: .never
                case .words: .words
                case .sentences: .sentences
                case .allCharacters: .characters
                @unknown default: .sentences
            }
        }
        let returnKeyType: SubmitLabel = value.returnKeyType.flatMap {
            switch UIReturnKeyType(rawValue: $0) ?? .default {
                case .default: .return
                case .go: .go
                case .join: .join
                case .next: .next
                case .route: .route
                case .search: .search
                case .send: .send
                case .done: .done
                case .continue: .continue

                case .google: .return
                case .yahoo: .return
                case .emergencyCall: .return
                @unknown default: .return
            }
        } ?? .return

        HStack {
            if !setting.title.isEmpty {
                Text(setting.title)
                    .opacity(disabled ? disabledOpacity : 1)
                    .lineLimit(1)
                Spacer()
            }
            let text: Binding<String> = SettingsStore.shared.binding(key: key(setting.key))

            HStack(spacing: 4) {
                Group {
                    if value.secure ?? false {
                        SecureField(value.placeholder ?? "", text: text)
                    } else {
                        TextField(value.placeholder ?? "", text: text)
                    }
                }
                .focused($fieldFocused)
                .foregroundStyle(Color.secondaryLabel)
                .multilineTextAlignment(setting.title.isEmpty ? .leading : .trailing)
                .textInputAutocapitalization(autocapitalizationType)
                .autocorrectionDisabled(value.autocorrectionDisabled ?? false)
                .keyboardType(value.keyboardType.flatMap { UIKeyboardType(rawValue: $0) } ?? .default)
                .submitLabel(returnKeyType)
                .disabled(disabled)

                if !text.wrappedValue.isEmpty && fieldFocused {
                    ClearFieldButton {
                        text.wrappedValue = ""
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: Button View
extension SettingView {
    @ViewBuilder
    func buttonView(value: ButtonSetting) -> some View {
        Button(setting.title, role: (value.destructive ?? false) ? .destructive : nil) {
            if value.confirmTitle != nil || value.confirmText != nil {
                showButtonConfirm = true
            } else {
                handleValueChange()
            }
        }
        .lineLimit(1)
        .disabled(disabled)
        .confirmationDialogOrAlert(
            value.confirmTitle ?? "",
            isPresented: $showButtonConfirm,
            titleVisibility: value.confirmTitle != nil ? .visible : .hidden
        ) {
            Button(NSLocalizedString("OK"), role: value.destructive ?? false ? .destructive : nil) {
                handleValueChange()
            }
            Button(NSLocalizedString("CANCEL"), role: .cancel) {}
        } message: {
            if let text = value.confirmText {
                Text(text)
            }
        }
    }
}

// MARK: Link View
extension SettingView {
    @ViewBuilder
    func linkView(value: LinkSetting) -> some View {
        Button(setting.title) {
            showSafari = true
        }
        .lineLimit(1)
        .fullScreenCover(isPresented: $showSafari) {
            SafariView(url: Binding.constant(URL(string: value.url)))
                .ignoresSafeArea()
        }
        .disabled(disabled)
    }
}

// MARK: Login View
extension SettingView {
    @ViewBuilder
    func loginView(value: LoginSetting) -> some View {
        let key = key(setting.key)
        let loggedIn = !(SettingsStore.shared.get(key: key) as String).isEmpty
        Button {
            guard !loggedIn else {
                loginViewModel.showLogoutAlert = true
                return
            }
            switch value.method {
                case .basic:
                    if #available(iOS 16.0, *) {
                        loginViewModel.showLoginAlert = true
                    } else {
                        showLoginAlertView(value: value)
                    }
                case .oauth:
                    loginViewModel.handleOAuthLogin(value: value)
                case .web:
                    loginViewModel.showLoginWebConfirm = true
            }
        } label: {
            if loginViewModel.loginLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 20, height: 20)
            } else {
                Text(loggedIn ? value.logoutTitle ?? NSLocalizedString("LOGOUT") : setting.title)
                    .lineLimit(1)
            }
        }
        .disabled(disabled)
        .alert(setting.title, isPresented: $loginViewModel.showLoginAlert) {
            let useEmail = value.useEmail ?? false
            TextField(useEmail ? NSLocalizedString("EMAIL") : NSLocalizedString("USERNAME"), text: $loginViewModel.username)
                .textInputAutocapitalization(.never)
                .textContentType(useEmail ? .emailAddress : .username)
                .keyboardType(useEmail ? .emailAddress : .default)
                .autocorrectionDisabled()
                .submitLabel(.next)
            SecureField(NSLocalizedString("PASSWORD"), text: $loginViewModel.password)
                .textContentType(.password)
                .submitLabel(.done)

            Button(NSLocalizedString("CANCEL"), role: .cancel) {
                loginViewModel.loadCredentials()
            }
            let is16 = UIDevice.current.systemVersion.hasPrefix("16.")
            Button(NSLocalizedString("LOGIN")) {
                loginViewModel.handleBasicLogin(username: loginViewModel.username, password: loginViewModel.password)
            }
            .disabled(!is16 && (loginViewModel.username.isEmpty || loginViewModel.password.isEmpty))
        } message: {
            Text(NSLocalizedString("LOGIN_BASIC_TEXT"))
        }
        .alert(NSLocalizedString("LOGIN_WEBVIEW_WARNING"), isPresented: $loginViewModel.showLoginWebConfirm) {
            Button(NSLocalizedString("CANCEL"), role: .cancel) {}
            Button(NSLocalizedString("LOGIN")) {
                loginViewModel.showLoginWebView = true
            }
        } message: {
            Text(NSLocalizedString("LOGIN_WEBVIEW_WARNING_TEXT"))
        }
        .alert(NSLocalizedString("LOGOUT"), isPresented: $loginViewModel.showLogoutAlert) {
            Button(NSLocalizedString("CANCEL"), role: .cancel) {}
            Button(NSLocalizedString("OK")) {
                loginViewModel.logout(value: value)
            }
        } message: {
            Text(NSLocalizedString("LOGOUT_CONFIRM"))
        }
        .alert(NSLocalizedString("LOGIN_FAILED"), isPresented: $loginViewModel.showLoginFailAlert) {
            Button(NSLocalizedString("OK"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("LOGIN_FAILED_TEXT"))
        }
        .sheet(isPresented: $loginViewModel.showLoginWebView) {
            loginWebSheetView(value: value)
                .interactiveDismissDisabled()
        }
        .onAppear {
            loginViewModel.loadCredentials()
        }
    }

    private func showLoginAlertView(value: LoginSetting) {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            return
        }
        var usernameTextField: UITextField?
        var passwordTextField: UITextField?
        delegate.presentAlert(
            title: setting.title,
            message: NSLocalizedString("LOGIN_BASIC_TEXT"),
            actions: [
                UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel),
                UIAlertAction(title: NSLocalizedString("LOGIN"), style: .default) { _ in
                    guard
                        let username = usernameTextField?.text,
                        let password = passwordTextField?.text
                    else { return }
                    loginViewModel.handleBasicLogin(username: username, password: password)
                }
            ],
            textFieldHandlers: [
                { textField in
                    let useEmail = value.useEmail ?? false
                    textField.placeholder = useEmail ? NSLocalizedString("EMAIL") : NSLocalizedString("USERNAME")
                    textField.textContentType = useEmail ? .emailAddress : .username
                    textField.keyboardType = useEmail ? .emailAddress : .default
                    textField.autocorrectionType = .no
                    textField.autocapitalizationType = .none
                    textField.returnKeyType = .next
                    usernameTextField = textField
                },
                { textField in
                    textField.isSecureTextEntry = true
                    textField.placeholder = NSLocalizedString("PASSWORD")
                    textField.textContentType = .password
                    textField.returnKeyType = .done
                    passwordTextField = textField
                }
            ]
        )
    }

    private func loginWebSheetView(value: LoginSetting) -> some View {
        PlatformNavigationStack {
            Group {
                if let url = value.url.flatMap({ URL(string: $0) }) {
                    WebView(
                        url,
                        localStorageKeys: value.localStorageKeys ?? [],
                        cookies: $loginViewModel.loginCookies,
                        localStorage: $loginViewModel.loginLocalStorage,
                        reloadToggle: $loginViewModel.loginReload
                    )
                    .edgesIgnoringSafeArea(.bottom)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton {
                        loginViewModel.showLoginWebView = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loginViewModel.loginReload = true
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle(setting.title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: loginViewModel.loginCookies) { newValue in
                loginViewModel.commitWebLogin(cookies: newValue)
                if let source, source.features.handlesWebLogin {
                    Task {
                        do {
                            let success = try await source.handleWebLogin(key: setting.key, cookies: newValue)
                            if success {
                                loginViewModel.showLoginWebView = false
                            }
                        } catch {
                            LogManager.logger.error("Error handling web login for \(source.key): \(error)")
                        }
                    }
                }
            }
            .onChange(of: loginViewModel.loginLocalStorage) { newValue in
                loginViewModel.saveLocalStorage(newValue)
            }
        }
    }
}

// MARK: Page View
extension SettingView {
    @ViewBuilder
    func pageView(value: PageSetting) -> some View {
        Button {
            if value.authToOpen ?? false {
                Task {
                    let success = await auth()
                    if success {
                        pageIsActive = true
                    }
                }
            } else {
                pageIsActive = true
            }
        } label: {
            NavigationLink(
                destination: SettingPageDestination(
                    source: source,
                    setting: setting,
                    namespace: namespace,
                    onChange: onChange,
                    value: value
                )
                .environment(\.settingPageContent, pageContentHandler)
                .environment(\.settingCustomContent, customContentHandler),
                isActive: $pageIsActive
            ) {
                if let icon = value.icon {
                    HStack(spacing: 15) {
                        SettingHeaderView.iconView(source: source, icon: SettingHeaderView.Icon.from(icon), size: 29)

                        Text(setting.title)
                            .lineLimit(1)

                        Spacer()
                    }
                } else {
                    Text(setting.title)
                        .lineLimit(1)
                }
            }
            .environment(\.isEnabled, true) // remove double disabled effect
        }
        .foregroundStyle(.primary)
        .disabled(disabled)
        .opacity({
            if #available(iOS 26.0, *) {
                1
            } else {
                disabled ? disabledOpacity : 1
            }
        }())
    }
}

// MARK: Editable List View
extension SettingView {
    @ViewBuilder
    func editableListView(value: EditableListSetting) -> some View {
        let items = ForEach(stringListBinding, id: \.self) { item in
            Text(item)
                .lineLimit(value.lineLimit ?? 0)
        }
        .onDelete { indexSet in
            let newValues: [String] = stringListBinding.enumerated().compactMap { offset, item in
                if indexSet.contains(offset) {
                    nil
                } else {
                    item
                }
            }
            stringListBinding = newValues
        }
        Group {
            if value.inline ?? false {
                items
                Button {
                    showListAddPrompt(value: value)
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text(NSLocalizedString("ADD"))
                    }
                }
                .disabled(disabled)
            } else {
                NavigationLink {
                    List {
                        items
                    }
                    .navigationTitle(setting.title)
                    .toolbar {
#if !os(macOS)
                        let placement = ToolbarItemPlacement.topBarTrailing
#else
                        let placement = ToolbarItemPlacement.primaryAction
#endif
                        ToolbarItem(placement: placement) {
                            Button {
                                showListAddPrompt(value: value)
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                } label: {
                    Text(setting.title)
                }
                .disabled(disabled)
            }
        }
    }

    func showListAddPrompt(value: EditableListSetting) {
        var alertTextField: UITextField?
        (UIApplication.shared.delegate as? AppDelegate)?.presentAlert(
            title: setting.title,
            actions: [
                UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel),
                UIAlertAction(title: NSLocalizedString("ADD"), style: .default) { _ in
                    guard let text = alertTextField?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                    stringListBinding.append(text)
                }
            ],
            textFieldHandlers: [
                { textField in
                    textField.placeholder = value.placeholder ?? ""
                    textField.autocorrectionType = .no
                    textField.returnKeyType = .done
                    alertTextField = textField
                }
            ],
            textFieldDisablesLastActionWhenEmpty: true
        )
    }
}

// MARK: Editable List View
extension SettingView {
    @ViewBuilder
    func customView() -> some View {
        Group {
            if let customContentHandler {
                customContentHandler(setting)
            } else {
                Text("Missing custom content handler for key \(setting.key)")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
    }
}

#Preview {
    let settings: [Setting] = [
        .init(
            title: "Group",
            value: .group(.init(
                footer: "This is a footer.",
                items: [
                    .init(
                        key: "select",
                        title: "Select",
                        value: .select(.init(
                            values: ["1", "2", "3"],
                            titles: ["One", "Two", "Three"]
                        ))
                    ),
                    .init(
                        key: "multi-select",
                        title: "Multi-Select",
                        value: .multiselect(.init(
                            values: ["4", "5", "6"],
                            titles: ["Four", "Five", "Six"]
                        ))
                    ),
                    .init(
                        key: "switch",
                        title: "Switch",
                        value: .toggle(.init(
                            subtitle: "Switch Subtitle"
                        ))
                    )
                ]
            ))
        )
    ]
    return PlatformNavigationStack {
        List {
            ForEach(Array(settings.enumerated()), id: \.offset) { _, setting in
                SettingView(source: nil, setting: setting)
            }
        }
        .navigationTitle("Settings")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
