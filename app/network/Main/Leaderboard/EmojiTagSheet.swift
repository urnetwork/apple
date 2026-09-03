//
//  EmojiTagSheet.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * The emoji tag editor. The tag is picked on an emoji-only keyboard, never
 * the system text keyboard: the field is a read-only display of the draft
 * with a backspace key that removes one emoji at a time. A network with no
 * tag starts from a random 1-3 emoji suggestion from the sdk
 * (`SdkSuggestEmojiTag`), and the shuffle key re-rolls it; a suggestion is
 * only a draft until Save. Every change is validated by the sdk exactly the
 * way the server validates it, and the counter reads "n / max". `onSave`
 * gets the sdk's normalized tag; `onClear` sends an empty tag.
 */
struct EmojiTagSheet: View {
    @EnvironmentObject var themeManager: ThemeManager

    let currentTag: String
    let isSaving: Bool
    let saveError: String?
    let onSave: (String) -> Void
    let onClear: () -> Void
    let onDismiss: () -> Void

    @State private var draft: String

    init(
        currentTag: String,
        isSaving: Bool,
        saveError: String?,
        onSave: @escaping (String) -> Void,
        onClear: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.currentTag = currentTag
        self.isSaving = isSaving
        self.saveError = saveError
        self.onSave = onSave
        self.onClear = onClear
        self.onDismiss = onDismiss
        _draft = State(initialValue: currentTag.isEmpty ? Self.suggestEmojiTag() : currentTag)
    }

    /// a random 1-3 emoji draft from the sdk
    private static func suggestEmojiTag() -> String {
        SdkSuggestEmojiTag(0)
    }

    var body: some View {
        let maxCount = Int(SdkEmojiTagMaxCount)
        // the sdk validates exactly the way the server does; run it on every
        // change so the counter and Save always reflect what the server would say
        let validation = SdkValidateEmojiTag(draft)
        let ok = validation?.ok ?? false
        let count = validation?.count ?? 0
        let normalized = validation?.normalized ?? ""
        let error = EmojiTagEditor.errorFor(ok: ok, reason: validation?.reason)
        let showsError = EmojiTagEditor.showsError(text: draft, error: error)
        let canSave = EmojiTagEditor.canSave(ok: ok, normalized: normalized, currentTag: currentTag, isSaving: isSaving)
        let full = ok && count >= maxCount

        VStack(alignment: .leading, spacing: 0) {
            Text("Emoji tag")
                .font(themeManager.currentTheme.titleFont)
                .foregroundStyle(themeManager.currentTheme.textColor)

            Spacer().frame(height: 8)

            Text(String(format: String(localized: "Pick 1 to %d emoji to show next to your network."), Int32(maxCount)))
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)

            Spacer().frame(height: 16)

            // the draft: read-only, edited only through the keys below
            HStack(spacing: 4) {
                HStack {
                    Text(draft)
                        .font(.system(size: 28))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 56)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(12)

                Button(action: {
                    draft = EmojiTagEditor.dropLastEmoji(draft)
                }) {
                    Image(systemName: "delete.left")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty || isSaving)
                .accessibilityLabel(Text("Delete last emoji"))

                Button(action: {
                    draft = Self.suggestEmojiTag()
                }) {
                    Image(systemName: "shuffle")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel(Text("Suggest another"))
            }

            Spacer().frame(height: 6)

            Group {
                if let saveError {
                    Text(saveError)
                } else if showsError {
                    switch error {
                    case .empty:
                        Text("Add at least one emoji.")
                    case .tooMany:
                        Text(String(format: String(localized: "Use at most %d emoji."), Int32(maxCount)))
                    case .notEmoji, .none:
                        Text("Only emoji are allowed.")
                    }
                } else {
                    Text(String(format: String(localized: "%1$d / %2$d"), Int32(count), Int32(maxCount)))
                }
            }
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundStyle(
                showsError || saveError != nil
                    ? themeManager.currentTheme.dangerColor
                    : themeManager.currentTheme.textMutedColor
            )

            Spacer().frame(height: 12)

            // the keyboard: emoji only
            EmojiKeyboardView(onPick: { emoji in
                if !full {
                    draft += emoji
                }
            })
            .frame(height: 320)
            .background(themeManager.currentTheme.borderBaseColor)
            .cornerRadius(12)

            Spacer().frame(height: 12)

            HStack(spacing: 8) {
                Spacer()
                if !currentTag.isEmpty {
                    Button(action: onClear) {
                        Text("Clear")
                    }
                    .disabled(isSaving)
                }
                Button(action: onDismiss) {
                    Text("Cancel")
                }
                .disabled(isSaving)
                Button(action: {
                    if canSave {
                        onSave(normalized)
                    }
                }) {
                    Text("Save")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
    }
}

/**
 * The emoji-only keyboard: every key appends one emoji to the draft. The keys
 * come from `EmojiKeyboardCatalog`; the sdk still validates the whole tag on
 * every change, so the keyboard cannot produce anything the server rejects.
 */
private struct EmojiKeyboardView: View {
    let onPick: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 40), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(EmojiKeyboardCatalog.sections) { section in
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(section.emoji, id: \.self) { emoji in
                            Button(action: {
                                onPick(emoji)
                            }) {
                                Text(emoji)
                                    .font(.system(size: 26))
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(emoji))
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}
