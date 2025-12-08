//
//  LanguageSelectorView.swift
//  ios_realtime_trans
//
//  語言選擇器視圖元件
//  支援全螢幕語言選擇介面
//

import SwiftUI

// MARK: - 語言選擇按鈕（點擊後彈出全螢幕選擇器）
struct LanguageSelectorView: View {
    @Binding var sourceLang: Language
    @Binding var targetLang: Language
    let isDisabled: Bool

    // 控制全螢幕選擇器的顯示
    @State private var showSourcePicker = false
    @State private var showTargetPicker = false

    var body: some View {
        HStack(spacing: 12) {
            // 來源語言按鈕
            VStack(alignment: .leading, spacing: 4) {
                Text("來源語言")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showSourcePicker = true
                } label: {
                    HStack {
                        Text(sourceLang.displayName)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
            .frame(maxWidth: .infinity)

            // 交換箭頭
            Button {
                let temp = sourceLang
                if targetLang != .auto {
                    sourceLang = targetLang
                    targetLang = temp
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundStyle(.purple)
            }
            .disabled(isDisabled || targetLang == .auto)
            .padding(.top, 20)

            // 目標語言按鈕
            VStack(alignment: .leading, spacing: 4) {
                Text("目標語言")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showTargetPicker = true
                } label: {
                    HStack {
                        Text(targetLang.displayName)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
            .frame(maxWidth: .infinity)
        }
        // 來源語言全螢幕選擇器
        .fullScreenCover(isPresented: $showSourcePicker) {
            LanguagePickerSheet(
                selectedLanguage: $sourceLang,
                title: "選擇來源語言",
                includeAuto: true
            )
        }
        // 目標語言全螢幕選擇器
        .fullScreenCover(isPresented: $showTargetPicker) {
            LanguagePickerSheet(
                selectedLanguage: $targetLang,
                title: "選擇目標語言",
                includeAuto: false  // 目標語言不能選自動
            )
        }
    }
}

// MARK: - 全螢幕語言選擇器
struct LanguagePickerSheet: View {
    @Binding var selectedLanguage: Language
    let title: String
    let includeAuto: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    // 根據搜尋過濾語言列表
    private var filteredLanguages: [Language] {
        let languages = includeAuto ? Language.allCases : Language.allCases.filter { $0 != .auto }

        if searchText.isEmpty {
            return languages
        }

        return languages.filter { language in
            language.displayName.localizedCaseInsensitiveContains(searchText) ||
            language.rawValue.localizedCaseInsensitiveContains(searchText) ||
            language.shortName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredLanguages) { language in
                    LanguageRow(
                        language: language,
                        isSelected: selectedLanguage == language
                    ) {
                        selectedLanguage = language
                        dismiss()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "搜尋語言...")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 語言列表項目
struct LanguageRow: View {
    let language: Language
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // 國旗（大型顯示）
                Text(language.flag)
                    .font(.system(size: 32))

                // 語言名稱
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.shortName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(language.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 選中標記
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.purple.opacity(0.1) : Color.clear)
    }
}

// MARK: - Preview
#Preview("Language Selector") {
    @Previewable @State var sourceLang: Language = .zh
    @Previewable @State var targetLang: Language = .en

    LanguageSelectorView(
        sourceLang: $sourceLang,
        targetLang: $targetLang,
        isDisabled: false
    )
    .padding()
}

#Preview("Language Picker Sheet") {
    @Previewable @State var selectedLang: Language = .zh

    LanguagePickerSheet(
        selectedLanguage: $selectedLang,
        title: "選擇語言",
        includeAuto: true
    )
}
