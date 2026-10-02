import Testing
import MerryCore
@testable import MerryUI

// MARK: - The shortcut

@Suite struct AcceleratorTests {
    @Test func keyCapsMatchTheOriginal() {
        for row in Fixture.load("shortcut-keys").arrayValue ?? [] {
            #expect(Accelerator.display(row.str("accelerator")) == row.strings("keys"), "\(row.str("accelerator"))")
        }
    }

    @Test func chordsAreSpelledAsTheOriginalStoresThem() {
        #expect(Chord.accelerator("cs", key: "Space") == "Command+Shift+Space")
        #expect(Chord.accelerator("os", key: "Space") == "Alt+Shift+Space")
        #expect(Chord.accelerator("cs", key: "K") == "Command+Shift+K")
        #expect(Chord.accelerator("o", key: "Space") == "Alt+Space")
        #expect(Chord.accelerator("t", key: "F5") == "Control+F5")
        // Modifiers always come in the same order: ⌘ ⌃ ⌥ ⇧.
        #expect(Chord.accelerator("soct", key: "7") == "Command+Control+Alt+Shift+7")
        // A chord needs ⌘, ⌥ or ⌃.
        #expect(Chord.accelerator("", key: "K") == nil)
        #expect(Chord.accelerator("s", key: "K") == nil)
        // A bare modifier names no key.
        #expect(Chord.accelerator("c", key: nil) == nil)
        // ⌘Space is Spotlight's; with anything else held it is fine.
        #expect(Chord.accelerator("c", key: "Space") == nil)
        #expect(Chord.accelerator("ct", key: "Space") == "Command+Control+Space")
    }

    @Test func keysGoByTheirPlaceOnTheKeyboard() {
        #expect(Accelerator.key(forKeyCode: 49) == "Space")
        #expect(Accelerator.key(forKeyCode: 40) == "K")
        #expect(Accelerator.key(forKeyCode: 0) == "A")
        #expect(Accelerator.key(forKeyCode: 29) == "0")
        #expect(Accelerator.key(forKeyCode: 18) == "1")
        #expect(Accelerator.key(forKeyCode: 122) == "F1")
        #expect(Accelerator.key(forKeyCode: 111) == "F12")
        // Return, Tab, arrows and punctuation cannot end a shortcut.
        for code: UInt16 in [36, 48, 123, 124, 27, 51] { #expect(Accelerator.key(forKeyCode: code) == nil) }
    }

    @Test func recordingAChord() {
        #expect(Chord.capture("", keyCode: 53) == .cancelled)
        #expect(Chord.capture("cs", keyCode: 53) == .cancelled)
        #expect(Chord.capture("cs", keyCode: 40) == .accepted("Command+Shift+K"))
        #expect(Chord.capture("os", keyCode: 49) == .accepted("Alt+Shift+Space"))
        #expect(Chord.capture("", keyCode: 40) == .ignored)
        #expect(Chord.capture("c", keyCode: 36) == .ignored)
        #expect(Chord.capture("c", keyCode: 49) == .refused("⌘ Command + Space opens Spotlight. Pick another. ⌘ Command + ⇧ Shift + Space is the default."))
        // Every accepted chord is one the backend's check lets through.
        for letters in ["c", "t", "o", "cs", "ctos"] {
            for code: UInt16 in [0, 18, 49, 122] {
                if case .accepted(let accelerator) = Chord.capture(letters, keyCode: code) {
                    #expect(Rx("^[A-Za-z0-9+]{1,60}$").test(accelerator))
                    #expect(!Rx("^(Command|CommandOrControl|CmdOrCtrl|Cmd)\\+Space$").test(accelerator))
                }
            }
        }
    }
}

// MARK: - First-run tour

@MainActor @Suite struct WelcomeTests {
    @Test func cardsComeInTheOriginalOrder() {
        #expect(WelcomeModel.cards.map(\.id) == ["hello", "think", "files", "day", "web", "apps", "keep", "done"])
        #expect(WelcomeModel.cards.map(\.say) == ["Hi, I’m Merry.", "How should I think?", "Files.", "Your day.", "The web.", "Other apps.", "Remember & remind.", "That’s it."])
        #expect(WelcomeModel.cards[2].asks == ["folder:Downloads", "folder:Desktop", "folder:Documents"])
        #expect(WelcomeModel.cards[6].asks == ["notifications"])
    }

    @Test func aFirstRunOpensOnTheTourAndSkipNeverShowsItAgain() async {
        let bridge = SettingsFixtures.bridge()
        #expect(WelcomeModel.shouldShow(bridge.getSettings()))
        var done: [String?] = []
        let model = WelcomeModel(bridge: bridge) { done.append($0) }
        await model.load()
        #expect(model.index == 0)
        await model.finish()
        #expect(done.count == 1 && done[0] == nil)
        #expect(bridge.settings.onboarded)
        #expect(!WelcomeModel.shouldShow(bridge.getSettings()))
    }

    @Test func finishingStillLeavesWhenTheSaveFails() async {
        let bridge = SettingsFixtures.bridge()
        var done: [String?] = []
        let model = WelcomeModel(bridge: bridge) { done.append($0) }
        bridge.failure = "disk full"
        await model.finish("Organize my Downloads folder")
        #expect(done.count == 1 && done[0] == "Organize my Downloads folder")
    }

    @Test func everyInstalledCodingAppIsOfferedAndPickingOneSwitchesPlanningToIt() async {
        let bridge = SettingsFixtures.bridge()
        let model = WelcomeModel(bridge: bridge)
        await model.load()
        #expect(model.apps.filter(\.available).map(\.label) == ["Claude Code", "Codex"])
        #expect(model.thinking == nil)
        await model.chooseApp(.codex)
        #expect(bridge.settings.useClaudeCode && bridge.settings.codingApp == .codex)
        #expect(model.isOn(.codex) && !model.isOn(.claudeCode) && !model.keyChoiceIsOn)
        #expect(model.thinking == "Codex")
        #expect(model.picker?.app == .codex)
        await model.chooseApp(.claudeCode)
        #expect(bridge.settings.codingApp == .claudeCode && model.picker?.app == .claudeCode)
        // The API key is offered beside them.
        await model.chooseKey()
        #expect(!bridge.settings.useClaudeCode && model.keyChoiceIsOn && model.picker == nil)
    }

    @Test func anAppThatIsNotInstalledCannotBePicked() async {
        let bridge = SettingsFixtures.bridge()
        let model = WelcomeModel(bridge: bridge)
        await model.load()
        await model.chooseApp(.opencode)
        #expect(!bridge.settings.useClaudeCode)
        #expect(!bridge.calls.contains("setSettings"))
    }

    @Test func theKeysAreAskedForAndSaved() async {
        let bridge = SettingsFixtures.bridge()
        let model = WelcomeModel(bridge: bridge)
        await model.load()
        #expect(model.jevLine == "Off, using my own rules")
        model.jev = "  ts-key  "
        await model.saveJev()
        #expect(bridge.jevKey && model.hasJev && model.jev.isEmpty)
        #expect(model.jevLine == "On")
        await model.chooseApp(.codex)
        model.key = "sk-ant-x"
        await model.saveKey()
        #expect(bridge.apiKey && model.hasKey && model.key.isEmpty)
        // Saving an Anthropic key switches planning to it.
        #expect(!bridge.settings.useClaudeCode)
        #expect(model.thinking == "Claude Sonnet 5.5")
    }

    @Test func showingACardAsksForNothing() async {
        let bridge = SettingsFixtures.bridge()
        let model = WelcomeModel(bridge: bridge)
        await model.load()
        await model.setup.refresh()
        for index in WelcomeModel.cards.indices {
            model.go(to: index)
            _ = model.items
            _ = model.pending
            await model.setup.refresh()
        }
        #expect(!bridge.calls.contains { $0.hasPrefix("requestSetup") || $0.hasPrefix("requestPermission") || $0.hasPrefix("openSetupSettings") })
    }

    @Test func eachPermissionIsAskedForOnlyByItsOwnTap() async {
        let bridge = SettingsFixtures.bridge()
        let model = WelcomeModel(bridge: bridge)
        await model.load()
        await model.setup.refresh()
        model.go(to: 2)
        #expect(Set(model.items.map(\.id)) == ["folder:Desktop", "folder:Documents", "folder:Downloads"])
        await model.setup.request("folder:Documents")
        #expect(bridge.calls.filter { $0.hasPrefix("requestSetup") } == ["requestSetup:folder:Documents"])
        #expect(model.setup.items.first { $0.id == "folder:Documents" }?.status == .granted)
        #expect(model.setup.items.first { $0.id == "folder:Downloads" }?.status == .notAsked)
        // "Allow all" covers what is left on this card, and nothing from another.
        #expect(model.pending.map(\.id) == ["folder:Downloads"])
        await model.allowCard()
        #expect(bridge.calls.filter { $0.hasPrefix("requestSetup") } == ["requestSetup:folder:Documents", "requestSetup:folder:Downloads"])
        // Accessibility and Screen Recording open System Settings, so they are never part of "Allow all".
        model.go(to: 5)
        #expect(!model.pending.contains { $0.group == .control })
        // A denied one goes to System Settings instead of asking again.
        await model.setup.openSettings("screen-recording")
        #expect(bridge.calls.last == "openSetupSettings:screen-recording")
    }

    @Test func aFailedRequestSaysSoAndLeavesTheItemAlone() async {
        let bridge = SettingsFixtures.bridge()
        let setup = SetupModel(bridge: bridge)
        await setup.refresh()
        bridge.failure = "macOS said no"
        await setup.request("folder:Downloads")
        #expect(setup.error == "macOS said no" && setup.busy == nil)
        #expect(setup.items.first { $0.id == "folder:Downloads" }?.status == .notAsked)
    }

    @Test func theLastCardSumsUp() async {
        let bridge = SettingsFixtures.bridge()
        let model = WelcomeModel(bridge: bridge)
        await model.load()
        await model.setup.refresh()
        #expect(model.thinksWithLine == "Nothing yet. Files, reminders, calendar and notes only")
        #expect(model.allowedLine == "5 of 15 permissions")
        #expect(WelcomeModel.tryThese == ["Organize my Downloads folder", "What’s on my calendar tomorrow?", "Remind me to stretch in 30 minutes"])
    }

    @Test func theTourCanBeReadFromTheKeyboard() async {
        let model = WelcomeModel(bridge: SettingsFixtures.bridge())
        #expect(!model.handle(.left, editing: false))
        #expect(model.handle(.enter, editing: false) && model.index == 1)
        #expect(model.handle(.right, editing: false) && model.index == 2)
        // Typing in a field, or recording a shortcut, keeps the keys.
        #expect(!model.handle(.enter, editing: true) && model.index == 2)
        #expect(model.handle(.left, editing: false) && model.index == 1)
        model.go(to: WelcomeModel.cards.count - 1)
        // Enter on the last card is left for the button; it does not wrap.
        #expect(!model.handle(.enter, editing: false))
        #expect(model.handle(.right, editing: false) && model.isLast)
    }

    @Test func thePanelIsAsTallAsTheCard() {
        #expect(WelcomeModel.panelHeight(content: 120) == 300)
        #expect(WelcomeModel.panelHeight(content: 401) == 420)
        #expect(WelcomeModel.panelHeight(content: 2000) == 640)
    }
}

// MARK: - Model selection

@MainActor @Suite struct ModelPickerTests {
    @Test func aRecommendationIsADraftUntilChecked() async {
        let bridge = SettingsFixtures.bridge()
        let picker = SettingsFixtures.picker(bridge, app: .codex)
        await picker.load(refresh: false)
        #expect(picker.recommended?.id == "prov/best")
        picker.choose("prov/best")
        #expect(picker.choice == "prov/best" && picker.value.isEmpty)
        #expect(bridge.settings.codexModel.isEmpty)
        #expect(!bridge.calls.contains("setSettings") && !bridge.calls.contains { $0.hasPrefix("checkCodingModel") })
        #expect(picker.applyTitle == "Check & use model")
        await picker.checkAndSave()
        #expect(bridge.calls.contains("checkCodingModel:codex:prov/best"))
        #expect(bridge.settings.codexModel == "prov/best" && picker.value == "prov/best")
        #expect(picker.feedback == "Access checked and model saved for Merry." && !picker.failed)
        #expect(picker.label(picker.models[0]) == "Best · Access checked")
    }

    @Test func unavailableChoicesAreDisabledWithTheirReason() async {
        let bridge = SettingsFixtures.bridge()
        let picker = SettingsFixtures.picker(bridge, app: .codex)
        await picker.load(refresh: false)
        let locked = picker.rows.first { $0.id == "prov/locked" }
        #expect(locked?.disabled == true && locked?.title == "Locked · Unavailable" && locked?.reason == "Your plan does not include this model.")
        #expect(picker.rows.filter(\.disabled).count == 1)
        picker.choose("prov/locked")
        #expect(picker.choice.isEmpty)
        // An unavailable model is never the recommendation.
        var catalog = SettingsFixtures.catalog()
        catalog.models[0].access = "unavailable"
        bridge.catalog = catalog
        await picker.load(refresh: true)
        #expect(picker.recommended == nil)
    }

    @Test func aFailedCheckKeepsTheSavedModel() async {
        let bridge = SettingsFixtures.bridge()
        bridge.settings.codexModel = "other/plain"
        let picker = SettingsFixtures.picker(bridge, app: .codex, value: "other/plain")
        await picker.load(refresh: false)
        picker.choose("prov/free")
        bridge.modelCheck = CodingModelCheck(ok: false, message: "No quota left today.")
        await picker.checkAndSave()
        #expect(bridge.settings.codexModel == "other/plain" && picker.value == "other/plain")
        #expect(picker.failed && picker.shownFeedback == "No quota left today.")
        #expect(!bridge.calls.contains("setSettings"))
        // A passing network error can be retried: the choice is not disabled.
        #expect(picker.canApply)

        // A definite refusal disables the choice and says why.
        bridge.modelCheck = CodingModelCheck(ok: false, message: "Not on your plan.", unavailable: true)
        await picker.checkAndSave()
        #expect(picker.isUnavailable && !picker.canApply)
        #expect(picker.rows.first { $0.id == "prov/free" }?.disabled == true)
        #expect(picker.shownFeedback == nil)
        #expect(bridge.settings.codexModel == "other/plain")

        // A check that throws leaves things as they were too.
        picker.choose("prov/best")
        bridge.failure = "boom"
        await picker.checkAndSave()
        #expect(picker.feedback == "Couldn’t check or save this model. Your previous choice is still selected. Please retry.")
        #expect(bridge.settings.codexModel == "other/plain")
    }

    @Test func aLateCheckIsIgnoredAfterSwitchingApps() async {
        let gate = CheckGate()
        var saved: [String] = []
        let picker = ModelPickerModel(app: .codex, value: "", loadCatalog: { _ in SettingsFixtures.catalog() }, check: { await gate.wait($0) }, save: { saved.append($0) })
        await picker.load(refresh: false)
        picker.choose("prov/best")
        let running = Task { await picker.checkAndSave() }
        await gate.untilEntered()
        #expect(picker.checking)
        // Choosing something else while a check runs does nothing.
        picker.choose("other/plain")
        #expect(picker.choice == "prov/best")
        picker.retire()
        gate.release(CodingModelCheck(ok: true, message: "ok"))
        await running.value
        #expect(saved.isEmpty && picker.value.isEmpty && picker.feedback.isEmpty)
    }

    @Test func aLateCheckIsIgnoredWhenTheSavedModelChangedMeanwhile() async {
        let gate = CheckGate()
        var saved: [String] = []
        let picker = ModelPickerModel(app: .codex, value: "", loadCatalog: { _ in SettingsFixtures.catalog() }, check: { await gate.wait($0) }, save: { saved.append($0) })
        await picker.load(refresh: false)
        picker.choose("prov/best")
        let running = Task { await picker.checkAndSave() }
        await gate.untilEntered()
        picker.setValue("other/plain")
        gate.release(CodingModelCheck(ok: true, message: "ok"))
        await running.value
        #expect(saved.isEmpty && picker.value == "other/plain" && !picker.checking)
    }

    @Test func switchingAppsInSettingsDropsTheOldPickerAndItsCheck() async {
        let bridge = SettingsFixtures.bridge()
        bridge.settings.useClaudeCode = true
        bridge.settings.codingApp = .codex
        let tune = TuneModel(bridge: bridge)
        await tune.refresh()
        let codex = tune.picker
        #expect(codex?.app == .codex)
        await tune.chooseCodingApp(.claudeCode)
        #expect(tune.picker?.app == .claudeCode && tune.picker !== codex)
        // The Codex picker is retired: a check it finishes now saves nothing.
        codex?.choose("prov/best")
        await codex?.checkAndSave()
        #expect(bridge.settings.codexModel.isEmpty)
        await tune.setPlanWithCodingApp(false)
        #expect(tune.picker == nil)
    }

    @Test func eachAppKeepsItsOwnChoice() async {
        let bridge = SettingsFixtures.bridge()
        bridge.apps[2].available = true
        bridge.settings.useClaudeCode = true
        bridge.settings.codingApp = .codex
        let tune = TuneModel(bridge: bridge)
        await tune.refresh()
        await tune.picker?.load(refresh: false)
        tune.picker?.choose("prov/best")
        await tune.picker?.checkAndSave()
        await tune.chooseCodingApp(.opencode)
        #expect(tune.picker?.value == "")
        await tune.picker?.load(refresh: false)
        tune.picker?.choose("prov/free")
        await tune.picker?.checkAndSave()
        #expect(bridge.settings.codexModel == "prov/best")
        #expect(bridge.settings.opencodeModel == "prov/free")
        #expect(bridge.settings.claudeCodeModel == "sonnet")
        await tune.chooseCodingApp(.codex)
        #expect(tune.picker?.value == "prov/best" && tune.picker?.choice == "prov/best")
    }

    @Test func configuredDefaultsNeedNoCheck() async {
        let bridge = SettingsFixtures.bridge()
        bridge.settings.codexModel = "prov/best"
        let picker = SettingsFixtures.picker(bridge, app: .codex, value: "prov/best")
        await picker.load(refresh: false)
        #expect(picker.rows.first?.id == "" && picker.rows.first?.title == "Use configured default · prov/best")
        picker.choose("")
        #expect(picker.applyTitle == "Use configured default" && picker.canApply)
        await picker.checkAndSave()
        #expect(!bridge.calls.contains { $0.hasPrefix("checkCodingModel") })
        #expect(bridge.settings.codexModel.isEmpty)
        #expect(picker.feedback == "Merry will use your coding app’s configured default.")

        // Claude Code has no such thing: a model must be chosen.
        let claude = SettingsFixtures.picker(bridge, app: .claudeCode, value: "")
        await claude.load(refresh: false)
        #expect(!claude.rows.contains { $0.id.isEmpty })
        #expect(!claude.canApply)
    }

    @Test func freeFilteringAndSearch() async {
        let bridge = SettingsFixtures.bridge()
        let picker = SettingsFixtures.picker(bridge, app: .opencode, value: "other/plain")
        await picker.load(refresh: false)
        #expect(picker.visible.count == 4 && !picker.keepChoice)
        picker.freeOnly = true
        #expect(picker.visible.map(\.id) == ["prov/free"])
        #expect(picker.label(picker.visible[0]) == "Free One · Free")
        // The saved choice stays listed when the filter hides it.
        #expect(picker.rows.map(\.title) == ["Use configured default · prov/best", "Plain · saved choice", "Free One · Free"])
        picker.search = "  nothing like this "
        #expect(picker.listStatus?.text == "No matching models with confirmed free pricing.")
        picker.freeOnly = false
        #expect(picker.listStatus?.text == "No matching models.")
        picker.search = "OTHER/"
        #expect(picker.visible.map(\.id) == ["other/plain"])
        picker.search = ""
        picker.choose("prov/best")
        picker.search = "plain"
        #expect(picker.rows.contains { $0.title == "Best · pending choice" })
    }

    @Test func customModelIds() async {
        let bridge = SettingsFixtures.bridge()
        let codex = SettingsFixtures.picker(bridge, app: .codex)
        await codex.load(refresh: false)
        codex.toggleCustom()
        #expect(codex.custom && !codex.canApply)
        codex.draft = "has space"
        #expect(codex.invalidMessage == "Use an exact model ID without spaces (up to 256 characters).")
        codex.draft = "-flag"
        #expect(!codex.valid && !codex.canApply)
        codex.draft = "  gpt-custom[1m]  "
        #expect(codex.pending == "gpt-custom[1m]" && codex.valid && codex.invalidMessage == nil)
        await codex.checkAndSave()
        #expect(bridge.calls.contains("checkCodingModel:codex:gpt-custom[1m]"))
        #expect(bridge.settings.codexModel == "gpt-custom[1m]")

        let open = SettingsFixtures.picker(bridge, app: .opencode)
        await open.load(refresh: false)
        open.toggleCustom()
        for bad in ["model", "/model", "provider/"] {
            open.draft = bad
            #expect(open.invalidMessage == "Use a provider/model ID without spaces.", "\(bad)")
        }
        open.draft = "provider/model"
        #expect(open.valid)
        await open.checkAndSave()
        #expect(bridge.settings.opencodeModel == "provider/model")
    }

    @Test func aFailedCatalogRefreshKeepsTheChoice() async {
        let bridge = SettingsFixtures.bridge()
        bridge.settings.codexModel = "prov/free"
        let picker = SettingsFixtures.picker(bridge, app: .codex, value: "prov/free")
        await picker.load(refresh: false)
        #expect(picker.listStatus == nil)
        bridge.failure = "codex: not logged in"
        await picker.load(refresh: true)
        #expect(!picker.loading && picker.models.isEmpty)
        #expect(picker.listStatus?.text == "Couldn’t load Codex models. Check its installation and login, then refresh, or enter a model ID." && picker.listStatus?.isError == true)
        #expect(picker.choice == "prov/free" && picker.value == "prov/free")
        #expect(picker.rows.map(\.title) == ["Use configured default", "prov/free · saved choice"])
        #expect(bridge.settings.codexModel == "prov/free")
        // Refreshing again recovers.
        await picker.load(refresh: true)
        #expect(picker.models.count == 4 && picker.error.isEmpty)
    }

    @Test func anEmptyCatalogSaysWhatToDo() async {
        let bridge = SettingsFixtures.bridge()
        bridge.catalog = CodingModelCatalog(models: [], note: "")
        let picker = SettingsFixtures.picker(bridge, app: .opencode)
        #expect(picker.listStatus?.text == "Loading OpenCode models…")
        await picker.load(refresh: false)
        #expect(picker.listStatus?.text == "No models were listed. Set up OpenCode, refresh, or enter a model ID.")
    }
}

// MARK: - Settings

@MainActor @Suite struct TuneTests {
    @Test func keysAreSavedAndTheFieldsCleared() async {
        let bridge = SettingsFixtures.bridge()
        var changes = 0
        let tune = TuneModel(bridge: bridge, keysOnly: true) { changes += 1 }
        await tune.refresh()
        #expect(!tune.hasAnthropic && !tune.hasJev && changes == 1)
        tune.jev = " ts-key "
        await tune.save(.jev)
        #expect(bridge.jevKey && tune.hasJev && tune.jev.isEmpty && tune.note != nil && !tune.saving)
        tune.anthropic = "sk-ant-x"
        await tune.save(.anthropic)
        #expect(bridge.apiKey && tune.hasAnthropic && tune.anthropic.isEmpty)
        #expect(changes == 3)
    }

    @Test func onlyAppsFoundOnThisMacAreOffered() async {
        let bridge = SettingsFixtures.bridge()
        let tune = TuneModel(bridge: bridge)
        await tune.refresh()
        #expect(tune.offersCodingApps)
        await tune.setPlanWithCodingApp(true)
        #expect(bridge.settings.useClaudeCode && bridge.settings.codingApp == .claudeCode)
        #expect(tune.codingAppOptions.map(\.title) == ["Claude Code", "Codex"])
        await tune.chooseCodingApp(.opencode)
        #expect(bridge.settings.codingApp == .claudeCode)
        await tune.chooseCodingApp(.codex)
        #expect(bridge.settings.codingApp == .codex)

        // Turning it on when the saved app has gone falls to one that is installed.
        let other = SettingsFixtures.bridge()
        other.settings.codingApp = .opencode
        let second = TuneModel(bridge: other)
        await second.refresh()
        await second.setPlanWithCodingApp(true)
        #expect(other.settings.codingApp == .claudeCode)

        // With nothing installed there is nothing to offer.
        let bare = PreviewBridge()
        bare.apps = bare.apps.map { CodingAppStatus(id: $0.id, label: $0.label, available: false) }
        let third = TuneModel(bridge: bare)
        await third.refresh()
        #expect(!third.offersCodingApps)
    }

    @Test func aRefusedChangeSaysWhyAndChangesNothing() async {
        let bridge = SettingsFixtures.bridge()
        let tune = TuneModel(bridge: bridge)
        bridge.failure = "Open at login is available in an installed Merry build. During development, keep Merry running for reminders."
        await tune.update { $0.launchAtLogin = true }
        #expect(tune.error == "Open at login is available in an installed Merry build. During development, keep Merry running for reminders.")
        #expect(!tune.settings.launchAtLogin)
    }

    @Test func habitsAndThePetsPlaceAreSaved() async {
        let bridge = SettingsFixtures.bridge()
        let tune = TuneModel(bridge: bridge)
        await tune.update { $0.confirmEveryAction = true; $0.chatty = false; $0.workflowsFirst = false }
        #expect(bridge.settings.confirmEveryAction && !bridge.settings.chatty && !bridge.settings.workflowsFirst)
        // Exactly the four places the backend accepts.
        #expect(TuneView.petModes.map(\.value.rawValue) == ["ondemand", "desktop", "peek", "menubar"])
        await tune.update { $0.petMode = .menubar }
        #expect(tune.settings.petMode == .menubar)
        await tune.update { $0.shortcut = "Alt+Shift+Space" }
        #expect(tune.settings.shortcut == "Alt+Shift+Space")
    }

    @Test func theSpendLimitTakesOnlyANumberOfAtLeastTenCents() async {
        let bridge = SettingsFixtures.bridge()
        let tune = TuneModel(bridge: bridge)
        #expect(await tune.commitBudget("2.25") == "2.25")
        #expect(bridge.settings.maxUsdPerTask == 2.25)
        for bad in ["", "abc", "0.05", "-3", "nan", "inf"] {
            #expect(await tune.commitBudget(bad) == "2.25", "\(bad)")
        }
        #expect(bridge.settings.maxUsdPerTask == 2.25)
        #expect(await tune.commitBudget(" 3 ") == "3")
    }

    @Test func memoriesCanBeForgotten() async {
        let bridge = SettingsFixtures.bridge()
        bridge.memories = SettingsScreens.memories()
        let tune = TuneModel(bridge: bridge)
        await tune.loadMemories()
        #expect(tune.told.count == 3 && tune.learned.count == 2)
        await tune.forget("m2")
        #expect(tune.memories.map(\.id) == ["m1", "m3", "m4", "m5"])
        // Something learned elsewhere shows up without asking.
        bridge.events.memoriesChanged.send(Array(bridge.memories.prefix(1)))
        #expect(tune.memories.map(\.id) == ["m1"])
        tune.confirmingForget = true
        await tune.forgetEverything()
        #expect(tune.memories.isEmpty && bridge.memories.isEmpty && !tune.confirmingForget)
    }

    @Test func uninstallFailuresAreShown() async {
        let bridge = SettingsFixtures.bridge()
        let tune = TuneModel(bridge: bridge)
        bridge.failure = "Merry.app is not in Applications."
        await tune.uninstall()
        #expect(tune.error == "Merry.app is not in Applications." && !tune.uninstalling)
    }
}

// MARK: - Bench

@Suite struct BenchTests {
    @Test func timesAndCostReadAsTheOriginal() {
        #expect(BenchView.format(0.4) == "<1ms")
        #expect(BenchView.format(1) == "1ms")
        #expect(BenchView.format(12.5) == "12.5ms")
        #expect(BenchView.format(999) == "999ms")
        #expect(BenchView.format(1000) == "1.0s")
        #expect(BenchView.format(2340) == "2.3s")
        #expect([BenchView.band(99), BenchView.band(100), BenchView.band(999), BenchView.band(1000)] == ["fast", "ok", "ok", "slow"])
        #expect(BenchView.spentLine([]) == "nothing was charged for this measurement")
        #expect(BenchView.spentLine([BenchRow(group: "g", label: "l", ms: 1, detail: "", usd: 0.004212), BenchRow(group: "g", label: "m", ms: 1, detail: "", usd: 0.000004)]) == "this measurement cost $0.004216")
    }
}
