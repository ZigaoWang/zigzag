import Foundation
import Testing
@testable import Zigzag

@MainActor
struct PermissionPromptTests {
    @Test func denyComesFirstAndTheProminentYesLast() {
        let ordered = PermissionPrompt.actions(for: [.allow, .alternate("browser", "Open in Browser"), .deny])
        #expect(ordered.map(\.id) == ["deny", "browser", "allow"])
        #expect(ordered.last?.isProminent == true)
    }

    /// One question at a time in a window: the card that is up says how many wait their turn behind it, and says
    /// nothing when none do — an empty line would be a label with no work.
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

    /// Two tabs of one site, a page's two frames, a private window and the window itself each ask for themselves: only
    /// the same tab, frame and privacy's repeated question shares one card.
    @Test func twoAskersShareOnlyTheSameQuestion() {
        // Held, not temporaries: a freed object's address can be reused by the next one.
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
}
