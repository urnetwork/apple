//
//  SeedphraseDisplayView.swift
//  URnetwork
//

import SwiftUI

private struct SeedWord: Identifiable {
    let id: Int
    let word: String
}

struct SeedphraseDisplayView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let seedphrase: String
    let onConfirmed: (_ jwt: String) -> Void

    @State private var hasCopied = false

    private let words: [SeedWord]

    init(seedphrase: String, onConfirmed: @escaping (String) -> Void) {
        // Normalize: trim whitespace and collapse multiple spaces
        let normalized = seedphrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.seedphrase = normalized
        self.onConfirmed = onConfirmed
        let tokens = normalized.components(separatedBy: " ")
        self.words = tokens.enumerated().map { SeedWord(id: $0.offset, word: $0.element) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center) {

                    titleView
                    warningView
                    instructionsView

                    Spacer().frame(height: 32)

                    wordGridView

                    Spacer().frame(height: 24)

                    copyButton
                    confirmationButton

                }
                .padding()
                .frame(maxWidth: .infinity)
                .frame(maxWidth: 400)
            }
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .interactiveDismissDisabled(true)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Secure Your Account")
                        .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                }
            }
        }
    }

    private var titleView: some View {
        Text("Your Seedphrase")
            .foregroundColor(.urWhite)
            .font(themeManager.currentTheme.titleFont)
    }

    private var warningView: some View {
        Text("⚠️ This is the ONLY time you'll see this.")
            .foregroundColor(.urYellow)
            .font(themeManager.currentTheme.bodyFont.bold())
            .multilineTextAlignment(.center)
    }

    private var instructionsView: some View {
        Text("Write it down and store it somewhere safe. If you lose it, you'll lose access to your account.")
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .multilineTextAlignment(.center)
    }

    private var wordGridView: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(words) { seedWord in
                wordRowView(index: seedWord.id, word: seedWord.word)
            }
        }
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeManager.currentTheme.textMutedColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func wordRowView(index: Int, word: String) -> some View {
        HStack(spacing: 4) {
            Text(String(index + 1) + ".")
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 24, alignment: .trailing)
            Text(word)
                .foregroundColor(.urWhite)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(6)
    }

    private var copyButton: some View {
        UrButton(
            text: hasCopied ? "Copied!" : "Copy to Clipboard",
            action: {
                #if os(iOS)
                UIPasteboard.general.string = seedphrase
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(seedphrase, forType: .string)
                #endif
                hasCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    hasCopied = false
                }
            },
            enabled: !hasCopied
        )
    }

    private var confirmationButton: some View {
        UrButton(
            text: "I've Saved My Seedphrase",
            action: {
                onConfirmed(seedphrase)
            },
            enabled: true,
            isProcessing: false
        )
        .tint(.urGreen)
    }

}

#Preview {
    SeedphraseDisplayView(
        seedphrase: "abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor active activity",
        onConfirmed: { _ in }
    )
    .environmentObject(ThemeManager.shared)
}
