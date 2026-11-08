// Notes Create shows about residents: Lantern Bay residents can't be changed, so the screen offers your
// own copy, and a copy says it's yours to change.

import SwiftUI

/// Shown instead of the form when someone opens a resident in Create.
struct CreateResidentNote: View {
    let resident: Character
    let townName: String
    let onCopy: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                CharacterCardView(character: resident)
                    .frame(width: 200)
                HearthCard {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("\(resident.name) lives in \(townName)")
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Text("Town residents can't be changed. You can make your own copy of \(resident.name) and shape it however you like. The original stays in town just as they are.")
                            .font(HearthFont.body)
                            .foregroundStyle(.hearthText2)
                            .fixedSize(horizontal: false, vertical: true)
                        PillButton("Make a copy", symbol: "plus.square.on.square", action: onCopy)
                            .fullWidth()
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity)
        }
    }
}

/// At the top of the form while making a copy of a resident.
struct CreateCopyNote: View {
    let name: String

    var body: some View {
        HearthCard {
            Label("This is your own copy of \(name). Change anything you like. The original stays in town just as they are.",
                  systemImage: "plus.square.on.square")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
        }
    }
}
