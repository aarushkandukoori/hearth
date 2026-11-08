// "Delete everything": says plainly what goes, offers to remove downloaded models too, then asks once more
// before wiping. Afterwards Hearth starts fresh at onboarding (AppModel.wipeEverything resets settings).

import SwiftUI

struct DeleteEverythingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var alsoModels = false
    @State private var confirming = false
    @State private var isDeleting = false
    @State private var problem: String?

    private var modelBytes: Int64 {
        app.engine.installedModels.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.hearthDanger)
                        .frame(width: 64, height: 64)
                        .background(Color.hearthDanger.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)

                    Text("Delete everything?")
                        .modifier(SettingsScaledTitle(28))
                        .foregroundStyle(.hearthText)

                    Text("This removes from this iPhone:")
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText2)

                    VStack(alignment: .leading, spacing: Spacing.s) {
                        GoneItem(text: "Every chat, with its photos, pictures and voice notes")
                        GoneItem(text: "Characters you made or brought in")
                        GoneItem(text: "What characters remember about you")
                        GoneItem(text: "Your name, settings and App Lock")
                    }

                    if modelBytes > 0 {
                        HearthCard {
                            Toggle(isOn: $alsoModels) {
                                SettingsRowLabel(title: "Also delete downloaded models",
                                                 detail: "Frees about \(SettingsFormat.approximate(modelBytes)). You'd download one again later.",
                                                 symbol: "cpu.fill", tint: .hearthDanger)
                            }
                            .tint(.hearthDanger)
                        }
                    }

                    Text("Hearth will start fresh, like the first time you opened it. The residents of Lantern Bay will still be there to meet again.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                    Text("This can't be undone. To keep your chats, make an encrypted backup first.")
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthText)

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthDanger)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .hearthScreenBackground()
            .safeAreaInset(edge: .bottom) {
                Group {
                    if isDeleting {
                        HStack(spacing: Spacing.s) {
                            ProgressView()
                            Text("Deleting...")
                                .font(HearthFont.callout)
                                .foregroundStyle(.hearthText2)
                        }
                        .frame(minHeight: 48)
                    } else {
                        PillButton("Delete everything", symbol: "trash", kind: .danger) { confirming = true }
                            .fullWidth()
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.s)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .alert("Delete everything for good?", isPresented: $confirming) {
                Button("Delete everything", role: .destructive) {
                    Task { await deleteEverything() }
                }
                Button("Keep my things", role: .cancel) {}
            } message: {
                Text(alsoModels
                     ? "All chats, characters, memories, settings and downloaded models will be erased. This can't be undone."
                     : "All chats, characters, memories and settings will be erased. This can't be undone.")
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .onChange(of: app.vault.isLocked) { _, locked in
            if locked && !isDeleting { dismiss() }
        }
    }

    private func deleteEverything() async {
        isDeleting = true
        problem = nil
        do {
            try await app.wipeEverything(includeModels: alsoModels)
            dismiss() // RootView is already showing onboarding again
        } catch {
            problem = error.localizedDescription
            isDeleting = false
        }
    }
}

private struct GoneItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.hearthDanger)
                .accessibilityHidden(true)
            Text(text)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
        }
    }
}
