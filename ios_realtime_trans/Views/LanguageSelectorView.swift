//
//  LanguageSelectorView.swift
//  ios_realtime_trans
//
//  語言選擇器視圖元件
//

import SwiftUI

struct LanguageSelectorView: View {
    @Binding var sourceLang: Language
    @Binding var targetLang: Language
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 來源語言
            VStack(alignment: .leading, spacing: 4) {
                Text("來源語言")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(Language.allCases) { language in
                        Button {
                            sourceLang = language
                        } label: {
                            HStack {
                                Text(language.displayName)
                                if sourceLang == language {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(sourceLang.displayName)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
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

            // 目標語言
            VStack(alignment: .leading, spacing: 4) {
                Text("目標語言")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(Language.allCases.filter { $0 != .auto }) { language in
                        Button {
                            targetLang = language
                        } label: {
                            HStack {
                                Text(language.displayName)
                                if targetLang == language {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(targetLang.displayName)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                }
                .disabled(isDisabled)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    @Previewable @State var sourceLang: Language = .zh
    @Previewable @State var targetLang: Language = .en

    LanguageSelectorView(
        sourceLang: $sourceLang,
        targetLang: $targetLang,
        isDisabled: false
    )
    .padding()
}
