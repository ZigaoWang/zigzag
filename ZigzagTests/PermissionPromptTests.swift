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
