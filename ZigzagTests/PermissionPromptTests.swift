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
        #expect(always.scope == .site)
        #expect(PermissionAnswer(action: "newTab", remember: false).remember == false)
        // A rule's own answer is kept just as long, on the rule: the same shape, one more place to keep it on.
        #expect(PermissionAnswer(action: "handOff", scope: .rule).remember == true)
    }

    /// Every card offers this page and this site; a question a rule asked adds the rule, and the third index means it.
    @Test func aRuleQuestionAsksHowLongForThreeScopes() {
        #expect(PermissionPrompt.durationChoices().map(\.scope) == [.once, .site])
        let choices = PermissionPrompt.durationChoices(ruleScope: "Always for YouTube")
        #expect(choices.map(\.scope) == [.once, .site, .rule])
        #expect(choices.last?.title == "Always for YouTube")
        #expect(Set(choices.map(\.title)).count == choices.count)
    }

    /// The card hands back what was chosen: the chooser's entry survives (a picked place used to be dropped on the
    /// way out), and a live duration says how long it lasts. A disabled one never returns more than this time.
    @Test func theAnswerKeepsItsEntryAndItsScope() {
        let picked = PermissionAnswer(action: "allow", scope: .rule, choice: "mini")
        let kept = PermissionPrompt.handBack(picked, keeping: true)
        #expect(kept.scope == .rule)
        #expect(kept.choice == "mini")
        let once = PermissionPrompt.handBack(picked, keeping: false)
        #expect(once.scope == .once)
        #expect(once.choice == "mini")
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
