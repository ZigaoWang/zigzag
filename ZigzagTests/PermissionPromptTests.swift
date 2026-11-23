import AppKit
import Testing
import WebKit
@testable import Zigzag

@MainActor
struct PermissionPromptTests {
    @Test func denyComesFirstAndTheProminentYesLast() {
        let ordered = PermissionPrompt.actions(for: [.allow, .alternate("browser", "Open in Browser"), .deny])
        #expect(ordered.map(\.id) == ["deny", "browser", "allow"])
        #expect(ordered.last?.isProminent == true)
    }

    /// One question at a time per window; the card shows how many wait, and nothing when none do.
    @Test func aCardSaysHowManyWaitBehindIt() {
        #expect(PermissionPrompt.waitingBehind(questionsWaiting: 0) == nil)
        #expect(PermissionPrompt.waitingBehind(questionsWaiting: 1) == nil)
        #expect(PermissionPrompt.waitingBehind(questionsWaiting: 2) == 1)
        #expect(PermissionPrompt.waitingBehind(questionsWaiting: 4) == 3)
        #expect(PermissionPrompt.waitingLine(questionsWaiting: 1) == nil)
        #expect(PermissionPrompt.waitingLine(questionsWaiting: 3) != nil)
    }

    @Test func aQuestionWithFourActionsKeepsDenyFirst() {
        let ordered = PermissionPrompt.actions(for: [.deny, .alternate("thisTab", "This Tab"),
                                                    .alternate("newTab", "New Tab"), .alternate("mini", "Mini")])
        #expect(ordered.map(\.id) == ["deny", "thisTab", "newTab", "mini"])
        #expect(ordered.last?.isProminent == true)
    }

    @Test func theAnswerCarriesTheChosenActionAndDuration() {
        let always = PermissionAnswer(action: "newTab", remember: true)
        #expect(always.action == "newTab")
        #expect(always.remember == true)
        #expect(PermissionAnswer(action: "newTab", remember: false).remember == false)
    }

    @Test func aKnownSiteAnswerIsAlwaysAndTakesPrecedence() {
        let answer = SitePermissions.knownAnswer(site: true, page: false)
        #expect(answer?.action == "allow")
        #expect(answer?.remember == true)
    }

    @Test func aKnownPageAnswerIsThisTime() {
        let answer = SitePermissions.knownAnswer(site: nil, page: true)
        #expect(answer?.action == "allow")
        #expect(answer?.remember == false)
    }

    /// Different tabs, frames, privacy or windows each ask separately; only the same tab, frame and privacy share a card.
    @Test func twoAskersShareOnlyTheSameQuestion() {
        // Kept alive: a freed object's address could be reused.
        let firstWindow = NSObject(), secondWindow = NSObject()
        let window = ObjectIdentifier(firstWindow), otherWindow = ObjectIdentifier(secondWindow)
        let tab = UUID(), otherTab = UUID()
        let request = "Use your camera?"
        let key = PermissionPrompt.questionKey(origin: "https://example.com", answerKey: "https://example.com",
                                               tabID: tab, isPrivate: false, window: window, request: request)
        #expect(key == PermissionPrompt.questionKey(origin: "https://example.com", answerKey: "https://example.com",
                                                    tabID: tab, isPrivate: false, window: window, request: request))
        #expect(key != PermissionPrompt.questionKey(origin: "https://example.com", answerKey: "https://example.com",
                                                    tabID: otherTab, isPrivate: false, window: window, request: request))
        #expect(key != PermissionPrompt.questionKey(origin: "https://example.com",
                                                    answerKey: "https://example.com|embed:https://call.example.net",
                                                    tabID: tab, isPrivate: false, window: window, request: request))
        #expect(key != PermissionPrompt.questionKey(origin: "https://example.com", answerKey: "https://example.com",
                                                    tabID: tab, isPrivate: true, window: window, request: request))
        #expect(key != PermissionPrompt.questionKey(origin: "https://example.com", answerKey: "https://example.com",
                                                    tabID: tab, isPrivate: false, window: otherWindow, request: request))
        #expect(key != PermissionPrompt.questionKey(origin: "https://example.com", answerKey: "https://example.com",
                                                    tabID: tab, isPrivate: false, window: window, request: "Use your microphone?"))
    }

    @Test func aDisabledDropdownDimsAndKeepsItsExplanation() {
        let dropdown = DropdownButton()
        dropdown.options = [DropdownButton.Option(title: "This time"), DropdownButton.Option(title: "Always on this site")]
        dropdown.isEnabled = false
        dropdown.toolTip = "Private windows don’t remember answers."
        dropdown.layout()
        #expect(dropdown.alphaValue == Tokens.Opacity.disabled)
        #expect(dropdown.toolTip == "Private windows don’t remember answers.")
    }

    /// Cancel leads, Open last and filled.
    @Test func theAppQuestionPutsCancelFirstAndOpenLast() {
        let (question, actions) = ExternalLinks.question(app: "Lantern", site: "example.com")
        let ordered = PermissionPrompt.actions(for: actions)
        #expect(ordered.map(\.id) == ["cancel", "allow"])
        #expect(ordered.last?.isProminent == true)
        #expect(ordered.first?.isCancel == true)
        #expect(question.title == "Open Lantern")
        #expect(question.detail == "example.com wants to open the Lantern app.")
        #expect(question.rememberTitle == "Always allow example.com to open Lantern")
    }

    /// Open unchecked is this time, checked is Always; Cancel answers nothing.
    @Test func openMapsToOnceOrAlwaysAndCancelToNothing() {
        let (_, actions) = ExternalLinks.question(app: "Lantern", site: "example.com")
        let open = actions[1]
        let once = PermissionPrompt.answer(for: open, rememberChecked: false, canRemember: true)
        #expect(once?.action == "allow")
        #expect(once?.remember == false)
        let always = PermissionPrompt.answer(for: open, rememberChecked: true, canRemember: true)
        #expect(always?.action == "allow")
        #expect(always?.remember == true)
        #expect(PermissionPrompt.answer(for: .cancel, rememberChecked: true, canRemember: true) == nil)
    }

    /// Where nothing can be kept (private, http, a foreign frame) a checked box still means this time.
    @Test func nothingIsKeptWhereTheSiteCantRemember() {
        let answer = PermissionPrompt.answer(for: .allow, rememberChecked: true, canRemember: false)
        #expect(answer?.remember == false)
    }

    /// Notifications, camera, microphone and location start with Remember checked, as in Chrome; the rest don't.
    @Test func chromeKeptQuestionsStartWithRememberChecked() {
        #expect(SitePermissions.remembersByDefault(PermissionSubject.notifications))
        #expect(SitePermissions.remembersByDefault(PermissionSubject.location))
        #expect(SitePermissions.remembersByDefault(PermissionSubject.media(.camera)))
        #expect(SitePermissions.remembersByDefault(PermissionSubject.media(.microphone)))
        #expect(!SitePermissions.remembersByDefault(PermissionSubject.downloads))
        #expect(!SitePermissions.remembersByDefault(PermissionSubject.screen))
        #expect(!SitePermissions.remembersByDefault(PermissionSubject.popups))
    }

    /// A checked Remember in a private window keeps nothing for the site.
    @Test func aPrivateTabKeepsNothingForTheSite() {
        let origin = "https://remember-default-\(UUID().uuidString).test"
        defer { SitePermissions.remember(nil, subject: PermissionSubject.notifications, origin: origin) }
        SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true), subject: PermissionSubject.notifications,
                                       origin: origin, tab: nil, isPrivate: true)
        #expect(SitePermissions.action(PermissionSubject.notifications, origin: origin) == nil)
    }

    /// Other questions keep Remember for either answer, Don't Allow included.
    @Test func rememberStillKeepsADenyOnOtherQuestions() {
        let answer = PermissionPrompt.answer(for: .deny, rememberChecked: true, canRemember: true)
        #expect(answer?.action == "deny")
        #expect(answer?.remember == true)
    }

    /// An Always answer is saved under the app's own scheme.
    @Test func alwaysIsKeptForTheOneApp() {
        let always = PermissionAnswer(action: "allow", remember: true)
        #expect(ExternalLinks.storageSubject(for: always, scheme: "x-lantern") == PermissionSubject.app("x-lantern"))
    }

    /// Esc always cancels; Return and Tab are the card's only once it has the keyboard.
    @Test func keysAnswerOnlyWhenTheCardHasTheKeyboard() {
        #expect(PermissionPrompt.keyAction(keyCode: 53, modified: false, focused: false) == .cancel)
        #expect(PermissionPrompt.keyAction(keyCode: 53, modified: false, focused: true) == .cancel)
        #expect(PermissionPrompt.keyAction(keyCode: 36, modified: false, focused: false) == .pass)
        #expect(PermissionPrompt.keyAction(keyCode: 36, modified: false, focused: true) == .primary)
        #expect(PermissionPrompt.keyAction(keyCode: 76, modified: false, focused: true) == .primary)
        #expect(PermissionPrompt.keyAction(keyCode: 36, modified: true, focused: true) == .pass)
        #expect(PermissionPrompt.keyAction(keyCode: 48, modified: false, focused: true) == .next(back: false))
        #expect(PermissionPrompt.keyAction(keyCode: 48, modified: false, focused: true, shift: true) == .next(back: true))
        #expect(PermissionPrompt.keyAction(keyCode: 48, modified: false, focused: false) == .pass)
        #expect(PermissionPrompt.keyAction(keyCode: 0, modified: false, focused: true) == .pass)
    }

    /// One width when it fits, their own widths next, else one per row.
    @Test func answersNeverClip() {
        #expect(PermissionPrompt.answerLayout(widths: [80, 150], available: 400, gap: 8) == .shared)
        #expect(PermissionPrompt.answerLayout(widths: [80, 150], available: 308, gap: 8) == .shared)
        #expect(PermissionPrompt.answerLayout(widths: [80, 150], available: 300, gap: 8) == .own)
        #expect(PermissionPrompt.answerLayout(widths: [80, 150], available: 238, gap: 8) == .own)
        #expect(PermissionPrompt.answerLayout(widths: [80, 150], available: 237, gap: 8) == .stacked)
        #expect(PermissionPrompt.answerLayout(widths: [80], menu: 120, available: 208, gap: 8) == .shared)
        #expect(PermissionPrompt.answerLayout(widths: [80], menu: 120, available: 207, gap: 8) == .stacked)
        #expect(PermissionPrompt.answerLayout(widths: [300], available: 200, gap: 8) == .shared)
    }

    /// A checkbox: off by default, a click turns it on and says so.
    @Test func theCheckboxToggles() {
        let box = Checkbox(title: "Always allow example.com to open Lantern")
        var heard: Bool?
        box.onChange = { heard = $0 }
        #expect(box.isOn == false)
        #expect(box.accessibilityRole() == .checkBox)
        #expect(box.accessibilityLabel() == "Always allow example.com to open Lantern")
        #expect(box.accessibilityPerformPress())
        #expect(box.isOn == true)
        #expect(heard == true)
        #expect(box.accessibilityValue() as? Int == 1)
        // Wraps rather than clips when narrow.
        #expect(box.height(for: 120) > box.height(for: 1000))
    }

    /// The card follows the page's appearance, not the window's (#300); without a page color, the page's drawn appearance, else the window's.
    @Test func theCardTakesItsPagesLook() {
        let black = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        #expect(PermissionPrompt.look(pageColor: black, pageLook: .aqua) == .darkAqua)
        #expect(PermissionPrompt.look(pageColor: .white, pageLook: .darkAqua) == .aqua)
        #expect(PermissionPrompt.look(pageColor: nil, pageLook: .darkAqua) == .darkAqua)
        #expect(PermissionPrompt.look(pageColor: nil, pageLook: .aqua) == .aqua)
        #expect(PermissionPrompt.look(pageColor: nil, pageLook: nil) == nil)
    }

    /// A page's alert, confirm or prompt sheet takes the page's look as the card does (#300).
    @Test func thePageDialogSheetTakesItsPagesLook() {
        let page = WKWebView()
        page.appearance = NSAppearance(named: .darkAqua)
        #expect(PageDialogSheet.look(of: page) == .darkAqua)
        page.appearance = NSAppearance(named: .aqua)
        #expect(PageDialogSheet.look(of: page) == .aqua)
        page.appearance = nil
        #expect(PageDialogSheet.look(of: page) == nil)
    }

    // MARK: The pop-up question's split answer

    /// A split answer in a window, with its choices; `chosen` collects what it answers.
    private func split(accepts: @escaping () -> Bool = { true }, chosen: @escaping (Int) -> Void) -> (NSWindow, SplitPillButton) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let button = SplitPillButton()
        button.choices = ["This Tab", "New Tab", "Zigzag Mini"]
        button.accepts = accepts
        button.onChoose = chosen
        content.addSubview(button)
        button.pillFrame = NSRect(x: 100, y: 100, width: button.fittingWidth, height: Tokens.Page.controlHeight)
        button.layoutSubtreeIfNeeded()
        return (window, button)
    }

    private func key(_ code: UInt16, _ characters: String = "", in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func aClickOnTheMainPartAnswersWithTheShownChoice() {
        var chosen: [Int] = []
        let (window, button) = split { chosen.append($0) }
        #expect(button.main.accessibilityLabel() == "This Tab")
        #expect(button.main.accessibilityPerformPress())
        #expect(chosen == [0])
        #expect(MenuPanel.current == nil)
        _ = window
    }

    @Test func theChevronOpensTheMenuWithoutAnswering() throws {
        var chosen: [Int] = []
        let (window, button) = split { chosen.append($0) }
        #expect(button.more.accessibilityRole() == .popUpButton)
        #expect(button.more.accessibilityLabel() == String(localized: "More Choices"))
        #expect(button.more.accessibilityPerformPress())
        let menu = try #require(MenuPanel.current)
        #expect(menu.itemTitles == ["This Tab", "New Tab", "Zigzag Mini"])
        #expect(chosen.isEmpty)
        menu.close(animated: false)
        _ = window
    }

    @Test func aChoiceFromTheMenuAnswersWithIt() throws {
        var chosen: [Int] = []
        let (window, button) = split { chosen.append($0) }
        button.openMenu()
        let menu = try #require(MenuPanel.current)
        // Down to New Tab, then Return.
        while menu.highlightedIndex != 1 { #expect(menu.handleKey(key(125, in: window))) }
        #expect(menu.handleKey(key(36, "\r", in: window)))
        #expect(chosen == [1])
        #expect(MenuPanel.current == nil)
    }

    @Test func theFirstHalfSecondTakesNoClickOnEitherPart() throws {
        var open = false
        var chosen: [Int] = []
        let (window, button) = split(accepts: { open }) { chosen.append($0) }
        _ = button.main.accessibilityPerformPress()
        _ = button.more.accessibilityPerformPress()
        #expect(chosen.isEmpty)
        #expect(MenuPanel.current == nil)
        // A menu opened once it counts still takes no choice while it doesn't.
        open = true
        button.openMenu()
        let menu = try #require(MenuPanel.current)
        open = false
        #expect(menu.handleKey(key(36, "\r", in: window)))
        #expect(chosen.isEmpty)
        open = true
        button.chooseShown()
        #expect(chosen == [0])
    }

    /// A finger beside the pill, within its 36pt reach, still lands on the part it's nearest.
    @Test func eachPartTakesAFingerAtItsFullReach() {
        let (window, button) = split { _ in }
        let pill = button.pillFrame
        #expect(button.frame.height >= TouchGestures.target)
        let local = { (point: NSPoint) in button.convert(point, from: button.superview) }
        #expect(button.segment(at: local(NSPoint(x: pill.minX + 10, y: pill.minY - 3))) === button.main)
        #expect(button.segment(at: local(NSPoint(x: pill.maxX - 4, y: pill.maxY + 3))) === button.more)
        #expect(button.segment(at: local(NSPoint(x: pill.maxX - SplitPillButton.chevronWidth + 2, y: pill.midY))) === button.more)
        #expect(button.segment(at: local(NSPoint(x: pill.maxX - SplitPillButton.chevronWidth - 2, y: pill.midY))) === button.main)
        _ = window
    }

    @Test func theSplitsAnswerKeepsRememberAndTheDuration() {
        let choices: [PermissionAction] = [.alternate("thisTab", "This Tab"), .alternate("newTab", "New Tab"), .alternate("mini", "Zigzag Mini")]
        let kept = PermissionPrompt.menuAnswer(choices, index: 2, accepts: true, remember: true, scopeIndex: 1)
        #expect(kept?.action == "mini")
        #expect(kept?.remember == true)
        #expect(kept?.scopeIndex == 1)
        let once = PermissionPrompt.menuAnswer(choices, index: 0, accepts: true, remember: false, scopeIndex: 0)
        #expect(once?.action == "thisTab")
        #expect(once?.remember == false)
        #expect(PermissionPrompt.menuAnswer(choices, index: 0, accepts: false, remember: true, scopeIndex: 0) == nil)
        #expect(PermissionPrompt.menuAnswer(choices, index: 3, accepts: true, remember: false, scopeIndex: 0) == nil)
    }
}
