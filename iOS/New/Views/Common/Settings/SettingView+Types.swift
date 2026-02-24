//
//  SettingView+Types.swift
//  Aidoku
//
//  Created by Gemini on 2/16/26.
//

import SwiftUI
import AidokuRunner

struct ScrollOffsetPreferenceKey: PreferenceKey {
    typealias Value = CGFloat
    static var defaultValue: CGFloat { .zero }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value += nextValue()
    }
}

struct SettingPageDestination: View {
    var source: AidokuRunner.Source?
    let setting: Setting
    var namespace: String?
    var onChange: ((String) -> Void)?

    let value: PageSetting
    var scrollTo: Setting?

    @Environment(\.settingPageContent) private var pageContentHandler
    @Environment(\.settingCustomContent) private var customContentHandler

    @State private var hidePageNavbarTitle = false

    @Namespace private var scrollSpace

    init(
        source: AidokuRunner.Source? = nil,
        setting: Setting,
        namespace: String? = nil,
        onChange: ((String) -> Void)? = nil,
        value: PageSetting,
        scrollTo: Setting? = nil
    ) {
        self.source = source
        self.setting = setting
        self.namespace = namespace
        self.onChange = onChange
        self.value = value
        self.scrollTo = scrollTo

        // init with hidden navbar title when header view will exist
        self._hidePageNavbarTitle = State(initialValue: value.icon != nil && value.info != nil)
    }

    var body: some View {
        Group {
            if let content = pageContentHandler?(setting.key) {
                content
            } else {
                ScrollViewReader { proxy in
                    List {
                        if let icon = value.icon, let subtitle = value.info {
                            SettingHeaderView(
                                source: source,
                                icon: SettingHeaderView.Icon.from(icon),
                                title: setting.title,
                                subtitle: subtitle
                            )
                            .background(GeometryReader { geo in
                                let offset = -geo.frame(in: .named(scrollSpace)).minY
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self, value: offset)
                            })
                        }
                        ForEach(value.items.indices, id: \.self) { offset in
                            let setting = value.items[offset]
                            SettingView(source: source, setting: setting, namespace: namespace, onChange: onChange)
                                .environment(\.settingPageContent, pageContentHandler)
                                .environment(\.settingCustomContent, customContentHandler)
                                .tag(setting.key.isEmpty ? UUID().uuidString : setting.key)
                        }
                    }
                    .coordinateSpace(name: scrollSpace)
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        hidePageNavbarTitle = value < 0
                    }
                    .onAppear {
                        if let scrollTo {
                            proxy.scrollTo(scrollTo.key, anchor: .center)
                        }
                    }
                    .scrollDismissesKeyboardInteractively()
                }
            }
        }
        .navigationTitle(hidePageNavbarTitle ? "" : setting.title)
        .navigationBarTitleDisplayMode({
            let hasHeaderView = value.icon != nil && value.info != nil
            if hasHeaderView || (value.inlineTitle ?? false) {
                return .inline
            } else {
                return .automatic
            }
        }())
    }
}
