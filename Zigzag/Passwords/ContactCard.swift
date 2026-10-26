import Contacts
import Foundation

/// Your own card in Contacts ("My Card"), for filling forms: name, email, phone, company and address. Read only when
/// you pick it in a form, never stored by Zigzag.
@MainActor
enum ContactCard {
    /// Fill forms from your card. On by default; the first fill asks macOS for access to Contacts.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "FormsAutofill") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FormsAutofill") }
    }

    /// The values a form can ask for, keyed like HTML's autocomplete tokens.
    static func values() async -> [String: String]? {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        } else if status != .authorized {
            return nil
        }
        return await Task.detached { read() }.value
    }

    /// Reads the card off the main thread; only plain strings come back.
    nonisolated private static func read() -> [String: String]? {
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
                                       CNContactPostalAddressesKey, CNContactOrganizationNameKey].map { $0 as CNKeyDescriptor }
        guard let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else { return nil }
        var v: [String: String] = [:]
        let given = me.givenName, family = me.familyName
        if !given.isEmpty { v["given-name"] = given }
        if !family.isEmpty { v["family-name"] = family }
        let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { v["name"] = full }
        if let email = me.emailAddresses.first?.value as String? { v["email"] = email }
        if let phone = me.phoneNumbers.first?.value.stringValue { v["tel"] = phone }
        if !me.organizationName.isEmpty { v["organization"] = me.organizationName }
        if let address = (me.postalAddresses.first { $0.label == CNLabelHome } ?? me.postalAddresses.first)?.value {
            let lines = address.street.split(separator: "\n").map(String.init)
            if !address.street.isEmpty { v["street-address"] = address.street }
            if let first = lines.first { v["address-line1"] = first }
            if lines.count > 1 { v["address-line2"] = lines.dropFirst().joined(separator: ", ") }
            if !address.city.isEmpty { v["address-level2"] = address.city }
            if !address.state.isEmpty { v["address-level1"] = address.state }
            if !address.postalCode.isEmpty { v["postal-code"] = address.postalCode }
            if !address.country.isEmpty { v["country-name"] = address.country }
            if !address.isoCountryCode.isEmpty { v["country"] = address.isoCountryCode.uppercased() }
        }
        return v.isEmpty ? nil : v
    }

    /// What the menu says about the card: the name, and what else it holds.
    static func summary(_ values: [String: String]) -> (title: String, detail: String) {
        let title = values["name"] ?? values["email"] ?? "My Card"
        let extra = [values["email"].map { _ in "email" }, values["tel"].map { _ in "phone" }, values["street-address"].map { _ in "address" }]
            .compactMap { $0 }
        return (title, extra.isEmpty ? "From your card in Contacts" : "Fills " + ListFormatter.localizedString(byJoining: extra) + " from Contacts")
    }
}
