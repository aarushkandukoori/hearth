// Create and edit characters, Character.AI style: a live preview card, avatar choices, their words,
// voice, a home in Lantern Bay and media habits. Saves through Library; nothing leaves the iPhone.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// RootView shows this in the Create sheet (inside a NavigationStack) and as the `.create` route.
/// `editingID` nil makes a new character; a user character's id edits it; a resident's id offers a copy.
struct CreateCharacterView: View {
    let editingID: String?
    @Environment(AppModel.self) private var app

    init(editingID: String?) {
        self.editingID = editingID
    }

    var body: some View {
        let start = CreateEditor.start(editingID: editingID, app: app)
        CreateEditor(mode: start.mode, draft: start.draft)
            .id(editingID ?? "new")
    }
}

private struct CreateEditor: View {
    enum Mode: Equatable {
        /// A blank character (or one being imported from a card).
        case new
        /// One of the user's own characters.
        case edit
        /// A copy of a Lantern Bay resident (their name).
        case copy(String)
        /// A resident: they can't be changed, so the screen offers a copy.
        case resident(Character)
        /// The character to edit isn't here anymore.
        case missing
    }

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode
    @State private var draft: CreateDraft
    /// The draft as it was when the screen opened, for "discard changes?".
    @State private var original: CreateDraft
    @FocusState private var focus: CreateFocus?
    @State private var scrollTarget: CreateFocus?
    @State private var attemptedSave = false
    @State private var isSaving = false

    @State private var showDefinition: Bool
    @State private var showDayPlan: Bool
    @State private var showMedia = false
    @State private var showVoicePicker = false
    @State private var showAvatarSheet = false
    @State private var showDrawSheet = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isLoadingPicture = false
    @State private var showImporter = false
    @State private var confirmImport = false
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    /// The voice heard in a preview while "Automatic" was picked, so the new character keeps that voice.
    @State private var heardAutomaticVoiceID: String?
    @State private var toast: String?
    @State private var savedCount = 0
    @State private var problemCount = 0

    init(mode: Mode, draft: CreateDraft) {
        _mode = State(initialValue: mode)
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
        _showDefinition = State(initialValue: draft.hasDefinition)
        _showDayPlan = State(initialValue: !draft.dayPlaces.isEmpty)
    }

    var body: some View {
        content
            .hearthScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true) // Cancel asks first when there are unsaved changes
            .toolbar { toolbar }
            .interactiveDismissDisabled(isDirty)
            .hearthToast($toast)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .png]) { result in
                switch result {
                case .success(let url): importCard(from: url)
                case .failure: toast = "That file couldn't be opened."
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                loadPhoto(item)
            }
            .sheet(isPresented: $showAvatarSheet) {
                NavigationStack {
                    CreateAvatarSheet(avatar: $draft.avatar, accentHex: $draft.accentHex)
                }
                .presentationDetents([.medium, .large])
                .tint(.hearthAccent)
            }
            .sheet(isPresented: $showDrawSheet) {
                NavigationStack {
                    CreateDrawSheet(idea: draft.drawingIdea, style: app.settings.pictureStyle) { picture, idea in
                        withAnimation(.smooth) {
                            draft.avatar.picture = picture
                            draft.avatar.artPrompt = idea.isEmpty ? nil : idea
                        }
                    }
                }
                .tint(.hearthAccent)
            }
            .navigationDestination(isPresented: $showVoicePicker) {
                CreateVoicePicker(voiceID: $draft.voiceID, onSample: playVoice, onStop: { CreateVoicePreview.stop(app) })
            }
            .sensoryFeedback(.success, trigger: savedCount) { _, _ in app.settings.haptics }
            .sensoryFeedback(.error, trigger: problemCount) { _, _ in app.settings.haptics }
            .onDisappear { CreateVoicePreview.stop(app) }
    }

    // MARK: Screens

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .missing:
            EmptyStateView(symbol: "questionmark.circle", title: "Character not found",
                           message: "This character isn't on this iPhone anymore.", actionTitle: "Close", action: close)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .resident(let resident):
            CreateResidentNote(resident: resident, townName: app.library.world.name) { makeCopy(of: resident) }
        case .new, .edit, .copy:
            form
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    if case .copy(let name) = mode { CreateCopyNote(name: name) }
                    preview
                    CreateBasicsSection(draft: $draft, focus: $focus, showErrors: attemptedSave)
                    CreatePersonalitySection(draft: $draft, focus: $focus, showDefinition: $showDefinition)
                    if !app.library.world.categories.isEmpty {
                        CreateCategoriesSection(draft: $draft, categories: app.library.world.categories)
                    }
                    CreateSection("Voice", subtitle: "How they sound in voice notes, calls and when you play a message aloud.") {
                        CreateVoiceSection(draft: $draft, voiceName: voiceName,
                                           isPreviewing: CreateVoicePreview.isPlaying(app),
                                           onChooseVoice: { showVoicePicker = true }, onPreview: togglePreview)
                    }
                    if !app.library.world.locations.isEmpty {
                        CreateSection(app.library.world.name) {
                            CreateTownSection(draft: $draft, locations: app.library.world.locations, showDayPlan: $showDayPlan)
                        }
                    }
                    CreateMediaSection(draft: $draft, isExpanded: $showMedia)
                    CreateVisibilityNote()
                    bottomButtons
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.smooth) { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
                // Focus once the scroll has settled, so the keyboard doesn't fight the animation.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    focus = target
                }
            }
        }
    }

    private var preview: some View {
        CreatePreviewHeader(character: previewCharacter, picture: draft.avatar.picture,
                            hasPicture: draft.avatar.hasPicture, isLoadingPicture: isLoadingPicture,
                            canDraw: app.pictures.isAvailable,
                            onPhoto: { showPhotoPicker = true },
                            onEmoji: { showAvatarSheet = true },
                            onDraw: { showDrawSheet = true },
                            onRemovePicture: { withAnimation(.smooth) { draft.avatar.removePicture() } })
    }

    private var bottomButtons: some View {
        VStack(spacing: Spacing.m) {
            PillButton(saveTitle, symbol: "checkmark", action: save)
                .fullWidth()
                .disabled(isSaving)
            if mode == .edit {
                PillButton("Delete character", symbol: "trash", kind: .danger) { confirmDelete = true }
                    .fullWidth()
                    .confirmationDialog("Delete \(CreateDraft.tidy(draft.name))?", isPresented: $confirmDelete,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive, action: deleteCharacter)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Their chats and what they remember about you are deleted too. This can't be undone.")
                    }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isEditable ? "Cancel" : "Close", action: cancelTapped)
                .confirmationDialog(mode == .edit ? "Discard your changes?" : "Discard this character?",
                                    isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive, action: close)
                    Button("Keep editing", role: .cancel) {}
                }
        }
        if mode == .new {
            ToolbarItem(placement: .primaryAction) {
                Button(action: importTapped) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .accessibilityLabel("Import a character card")
                .confirmationDialog("Import a character card?", isPresented: $confirmImport, titleVisibility: .visible) {
                    Button("Choose a card") { openImporterSoon() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The card's details replace what you've written so far.")
                }
            }
        }
        if isEditable {
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .edit ? "Save" : "Create", action: save)
                    .disabled(isSaving)
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focus = nil }
        }
    }

    // MARK: Derived

    private var isEditable: Bool {
        switch mode {
        case .new, .edit, .copy: return true
        case .resident, .missing: return false
        }
    }

    private var isDirty: Bool {
        isEditable && draft.comparable != original.comparable
    }

    private var title: String {
        switch mode {
        case .new: return "New character"
        case .edit, .missing: return "Edit character"
        case .copy: return "Your copy"
        case .resident(let resident): return resident.name
        }
    }

    private var saveTitle: String {
        if mode == .edit { return "Save changes" }
        let name = CreateDraft.tidy(draft.name)
        return name.isEmpty ? "Create character" : "Create \(name)"
    }

    /// The draft as a card, with friendly placeholders where it's still empty.
    private var previewCharacter: Character {
        var c = draft.makeCharacter(voice: nil, world: app.library.world)
        if c.name.isEmpty { c.name = "Your character" }
        if c.tagline.isEmpty { c.tagline = "Their tagline shows up here." }
        return c
    }

    private var voiceName: String {
        guard let id = draft.voiceID, let voice = app.voice.availableVoices.first(where: { $0.id == id }) else {
            return "Automatic"
        }
        return voice.quality == "Default" ? voice.name : "\(voice.name) (\(voice.quality))"
    }

    // MARK: Starting point

    /// What the screen opens with for `editingID`.
    @MainActor
    static func start(editingID: String?, app: AppModel) -> (mode: Mode, draft: CreateDraft) {
        guard let editingID else { return (.new, .fresh()) }
        guard let character = app.library.character(editingID) else { return (.missing, CreateDraft()) }
        if character.isBuiltIn { return (.resident(character), CreateDraft(from: character, voiceID: nil)) }
        return (.edit, CreateDraft(from: character, voiceID: currentVoiceID(for: character, app: app)))
    }

    /// The voice this character speaks with now: the user's override, else their preferred voice.
    @MainActor
    static func currentVoiceID(for character: Character, app: AppModel) -> String? {
        let voices = app.voice.availableVoices
        if let id = app.settings.voiceOverrides[character.id], voices.contains(where: { $0.id == id }) { return id }
        let locale = character.voice.locale?.lowercased()
        for wanted in character.voice.preferredVoiceNames ?? [] {
            let matches = voices.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            if let best = matches.first(where: { $0.language.lowercased() == locale }) ?? matches.first { return best.id }
        }
        return nil
    }

    // MARK: Avatar

    private func loadPhoto(_ item: PhotosPickerItem) {
        isLoadingPicture = true
        Task {
            defer { isLoadingPicture = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw LibraryError.imageUnreadable }
                let picture = try await CreatePicture.make(from: data)
                withAnimation(.smooth) {
                    draft.avatar.picture = picture
                    draft.avatar.artPrompt = nil
                }
            } catch {
                toast = LibraryError.imageUnreadable.errorDescription
            }
        }
    }

    // MARK: Voice

    private func playVoice(_ voiceID: String?) {
        let used = CreateVoicePreview.play(draft, voiceID: voiceID, app: app)
        if voiceID == nil, draft.id.isEmpty { heardAutomaticVoiceID = used }
    }

    private func togglePreview() {
        if CreateVoicePreview.isPlaying(app) {
            CreateVoicePreview.stop(app)
        } else {
            playVoice(draft.voiceID)
        }
    }

    // MARK: Import

    private func importTapped() {
        if isDirty { confirmImport = true } else { showImporter = true }
    }

    /// Opens the file picker once the confirmation has finished closing (two presentations can't overlap).
    private func openImporterSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            showImporter = true
        }
    }

    private func importCard(from url: URL) {
        isLoadingPicture = true
        Task {
            defer { isLoadingPicture = false }
            do {
                let card = try await Task.detached(priority: .userInitiated) {
                    // The file picker hands over a security-scoped URL; keep access open for the whole read.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try CharacterCardIO.importCard(from: url)
                }.value
                var picture: CreatePicture?
                if let data = card.avatar { picture = try? await CreatePicture.make(from: data) }
                applyImported(card.character, picture: picture)
            } catch {
                toast = (error as? LocalizedError)?.errorDescription ?? "That file couldn't be opened."
            }
        }
    }

    private func applyImported(_ character: Character, picture: CreatePicture?) {
        var imported = CreateDraft(from: character, voiceID: Self.currentVoiceID(for: character, app: app))
        imported.id = ""
        imported.name = String(CreateDraft.tidy(imported.name).prefix(CreateDraft.Limit.name))
        imported.tagline = CreateDraft.shortened(imported.tagline, to: CreateDraft.Limit.tagline)
        imported.avatar.picture = picture
        withAnimation(.smooth) {
            mode = .new
            draft = imported
            showDefinition = imported.hasDefinition
        }
        attemptedSave = false
        heardAutomaticVoiceID = nil
        toast = "\(imported.name) is filled in. Look it over, then tap Create."
        HearthLog.info("create", "card imported picture=\(picture != nil)")
    }

    // MARK: Copy of a resident

    private func makeCopy(of resident: Character) {
        var copy = CreateDraft(from: resident, voiceID: Self.currentVoiceID(for: resident, app: app))
        copy.id = ""
        // The copy lives outside the town until you move them in; the original keeps its place.
        copy.livesInTown = false
        copy.homeLocationID = nil
        copy.dayPlaces = [:]
        copy.base?.creator = "@you"
        copy.base?.relationships = []
        copy.base?.schedule = []
        copy.base?.homeLocationID = nil
        withAnimation(.smooth) {
            mode = .copy(resident.name)
            draft = copy
            original = copy
        }
    }

    // MARK: Save, cancel, delete

    private func save() {
        guard isEditable, !isSaving else { return }
        attemptedSave = true
        if let missing = draft.firstMissingField {
            problemCount += 1
            focus = nil
            scrollTarget = missing // scrolls there, then focuses the field
            return
        }
        isSaving = true
        focus = nil
        CreateVoicePreview.stop(app)
        let wasNew = mode != .edit
        // A new character keeps the voice heard in the preview, so what you heard is what you get.
        let chosenVoiceID = draft.voiceID ?? (draft.id.isEmpty ? heardAutomaticVoiceID : nil)
        let voice = app.voice.availableVoices.first { $0.id == chosenVoiceID }
        do {
            var saved = try app.library.save(draft.makeCharacter(voice: voice, world: app.library.world))
            var pictureKept = true
            if let picture = draft.avatar.picture {
                // The picture is written now that the character has an id.
                do {
                    saved.avatar = try app.library.saveAvatar(picture.data, for: saved.id)
                    saved = try app.library.save(saved)
                } catch {
                    pictureKept = false
                }
            }
            let savedID = saved.id
            app.settingsStore.update { settings in
                if let voice {
                    settings.voiceOverrides[savedID] = voice.id
                } else {
                    settings.voiceOverrides[savedID] = nil
                }
            }
            app.voice.assignDistinctVoices(for: app.library.allCharacters)
            savedCount += 1
            HearthLog.info("create", wasNew ? "character created" : "character updated")
            if pictureKept {
                showSaved(savedID, wasNew: wasNew)
            } else {
                // Stay here so the note can be read. The character itself is saved.
                let reloaded = CreateDraft(from: saved, voiceID: voice?.id)
                draft = reloaded
                original = reloaded
                mode = .edit
                isSaving = false
                toast = "Saved. The picture couldn't be kept, so they have their emoji for now."
            }
        } catch {
            isSaving = false
            problemCount += 1
            toast = (error as? LocalizedError)?.errorDescription ?? "That didn't save. Please try again."
        }
    }

    /// A new character opens on its profile on Home. After an edit, the screen underneath already shows it.
    private func showSaved(_ id: String, wasNew: Bool) {
        let profile = AppRoute.profile(characterID: id)
        if router.createSheet != nil {
            router.createSheet = nil
            if wasNew, router.visiblePath.last != profile { router.show(profile, in: .home) }
        } else {
            // Pushed as a route: swap this screen for the profile (or go back to the one it came from).
            var path = router.visiblePath
            if case .create = path.last { path.removeLast() }
            if wasNew, path.last != profile { path.append(profile) }
            router.visiblePath = path
        }
    }

    private func cancelTapped() {
        if isDirty { confirmDiscard = true } else { close() }
    }

    private func close() {
        CreateVoicePreview.stop(app)
        if router.createSheet != nil {
            router.createSheet = nil
        } else {
            dismiss()
        }
    }

    private func deleteCharacter() {
        let id = draft.id
        guard mode == .edit, !id.isEmpty else { return }
        CreateVoicePreview.stop(app)
        do {
            try app.deleteCharacter(id)
            app.settingsStore.update { $0.voiceOverrides[id] = nil }
            HearthLog.info("create", "character deleted")
            if router.createSheet != nil { router.createSheet = nil }
            removeRoutesToDeletedThings()
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? "That didn't delete. Please try again."
        }
    }

    /// Closes any open screens that showed the deleted character or its chats.
    private func removeRoutesToDeletedThings() {
        func stillThere(_ route: AppRoute) -> Bool {
            switch route {
            case .profile(let id), .startChat(let id), .newChat(let id), .memories(let id):
                return app.library.character(id) != nil
            case .create(let id):
                return id.map { app.library.character($0) != nil } ?? true
            case .chat(let conversationID):
                return app.chats.conversation(conversationID) != nil
            case .scene, .search, .settings:
                return true
            }
        }
        func kept(_ path: [AppRoute]) -> [AppRoute] {
            guard let first = path.firstIndex(where: { !stillThere($0) }) else { return path }
            return Array(path[..<first])
        }
        if kept(router.homePath) != router.homePath { router.homePath = kept(router.homePath) }
        if kept(router.townPath) != router.townPath { router.townPath = kept(router.townPath) }
        if kept(router.chatsPath) != router.chatsPath { router.chatsPath = kept(router.chatsPath) }
        if kept(router.youPath) != router.youPath { router.youPath = kept(router.youPath) }
    }
}

private extension Router {
    /// The navigation stack of the tab on screen.
    var visiblePath: [AppRoute] {
        get {
            switch tab {
            case .home, .create: return homePath
            case .town: return townPath
            case .chats: return chatsPath
            case .you: return youPath
            }
        }
        set {
            switch tab {
            case .home, .create: homePath = newValue
            case .town: townPath = newValue
            case .chats: chatsPath = newValue
            case .you: youPath = newValue
            }
        }
    }
}
