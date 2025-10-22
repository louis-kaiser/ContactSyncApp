import SwiftUI
import Contacts
import AppKit
import Combine

// MARK: - Models

/// Represents a potential duplicate contact requiring user resolution
struct DuplicateContact: Identifiable {
    let id = UUID()
    let contact: CNContact
    let sourceAccount: String
    
    var displayName: String {
        "\(contact.givenName) \(contact.familyName)"
    }
    
    var emailAddresses: String {
        contact.emailAddresses.map { $0.value as String }.joined(separator: ", ")
    }
}

/// Represents a contact account container
struct ContactAccount: Identifiable {
    let id: String
    let name: String
    let container: CNContainer
    var isSelected: Bool = false
}

// MARK: - Contact Synchronizer

@MainActor
class ContactSynchronizer: ObservableObject {
    @Published var accounts: [ContactAccount] = []
    @Published var isLoading = false
    @Published var statusMessage = ""
    @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined
    
    private let contactStore = CNContactStore()
    private var duplicateResolutions: [String: Bool] = [:] // Key: "firstName lastName", Value: areSame
    
    // MARK: - Initialization
    
    init() {
        updateAuthorizationStatus()
    }
    
    // MARK: - Authorization
    
    func updateAuthorizationStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }
    
    func requestAccess() async {
        do {
            let granted = try await contactStore.requestAccess(for: .contacts)
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                await loadAccounts()
            }
        } catch {
            statusMessage = "Access error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Account Management
    
    func loadAccounts() async {
        isLoading = true
        statusMessage = "Loading accounts..."
        
        do {
            let containers = try contactStore.containers(matching: nil)
            accounts = containers.map { container in
                ContactAccount(
                    id: container.identifier,
                    name: container.name,
                    container: container
                )
            }
            statusMessage = "Loaded \(accounts.count) account(s)"
        } catch {
            statusMessage = "Error loading accounts: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    // MARK: - Synchronization
    
    func synchronizeSelectedAccounts() async {
        let selectedAccounts = accounts.filter { $0.isSelected }
        
        guard selectedAccounts.count >= 2 else {
            statusMessage = "Please select at least 2 accounts to synchronize"
            return
        }
        
        isLoading = true
        statusMessage = "Starting synchronization..."
        duplicateResolutions.removeAll()
        
        do {
            // Step 1: Fetch all contacts from selected accounts
            statusMessage = "Fetching contacts from selected accounts..."
            var allContactsByAccount: [String: [CNContact]] = [:]
            
            for account in selectedAccounts {
                let contacts = try fetchContacts(from: account.container)
                allContactsByAccount[account.id] = contacts
            }
            
            // Step 2: De-duplicate and merge
            statusMessage = "De-duplicating contacts..."
            let mergedContacts = try await deduplicateAndMerge(contactsByAccount: allContactsByAccount)
            
            // Step 3: Sync to all selected accounts
            statusMessage = "Syncing \(mergedContacts.count) contacts to all accounts..."
            try await syncContactsToAccounts(contacts: mergedContacts, accounts: selectedAccounts)
            
            statusMessage = "✓ Synchronization complete! \(mergedContacts.count) contacts synced."
        } catch {
            statusMessage = "Sync error: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    // MARK: - Contact Fetching
    
    private func fetchContacts(from container: CNContainer) throws -> [CNContact] {
        let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
        let keys = [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactPostalAddressesKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            //CNContactNoteKey,
            CNContactBirthdayKey,
            CNContactDatesKey,
            CNContactUrlAddressesKey,
            CNContactSocialProfilesKey,
            CNContactInstantMessageAddressesKey
        ] as [CNKeyDescriptor]
        
        return try contactStore.unifiedContacts(matching: predicate, keysToFetch: keys)
    }
    
    // MARK: - De-duplication Logic
    
    private func deduplicateAndMerge(contactsByAccount: [String: [CNContact]]) async throws -> [CNMutableContact] {
        // Flatten all contacts
        var allContacts: [(contact: CNContact, accountId: String)] = []
        for (accountId, contacts) in contactsByAccount {
            allContacts.append(contentsOf: contacts.map { ($0, accountId) })
        }
        
        var processedIds = Set<String>()
        var mergedContacts: [CNMutableContact] = []
        
        for (index, item) in allContacts.enumerated() {
            let contact = item.contact
            
            // Skip if already processed
            if processedIds.contains(contact.identifier) {
                continue
            }
            
            // Find all duplicates
            var duplicates: [(contact: CNContact, accountId: String)] = [item]
            
            for otherIndex in (index + 1)..<allContacts.count {
                let otherItem = allContacts[otherIndex]
                let otherContact = otherItem.contact
                
                if processedIds.contains(otherContact.identifier) {
                    continue
                }
                
                if try await areDuplicates(contact, otherContact, item.accountId, otherItem.accountId) {
                    duplicates.append(otherItem)
                    processedIds.insert(otherContact.identifier)
                }
            }
            
            processedIds.insert(contact.identifier)
            
            // Merge duplicates if multiple found
            let merged = try await mergeContacts(duplicates.map { $0.contact })
            mergedContacts.append(merged)
        }
        
        return mergedContacts
    }
    
    private func areDuplicates(_ contact1: CNContact, _ contact2: CNContact, _ account1: String, _ account2: String) async throws -> Bool {
        // Priority 1: Unique identifier matching (same contact in different accounts)
        // Note: identifiers are unique per CNContactStore, so we use name matching
        
        // Priority 2: Name matching
        let name1 = "\(contact1.givenName) \(contact1.familyName)".trimmingCharacters(in: .whitespaces)
        let name2 = "\(contact2.givenName) \(contact2.familyName)".trimmingCharacters(in: .whitespaces)
        
        guard !name1.isEmpty && !name2.isEmpty && name1.lowercased() == name2.lowercased() else {
            return false
        }
        
        // Check if we already have a resolution for this name
        let nameLowercase = name1.lowercased()
        if let resolution = duplicateResolutions[nameLowercase] {
            return resolution
        }
        
        // Ask user for confirmation
        let areSame = await confirmDuplicate(contact1: contact1, contact2: contact2)
        duplicateResolutions[nameLowercase] = areSame
        
        return areSame
    }
    
    private func confirmDuplicate(contact1: CNContact, contact2: CNContact) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Duplicate Contact Detected"
                
                let name = "\(contact1.givenName) \(contact1.familyName)"
                let email1 = contact1.emailAddresses.map { $0.value as String }.joined(separator: ", ")
                let email2 = contact2.emailAddresses.map { $0.value as String }.joined(separator: ", ")
                
                var infoText = "Two contacts with the name '\(name)' were found.\n\n"
                if !email1.isEmpty {
                    infoText += "Contact 1 emails: \(email1)\n"
                }
                if !email2.isEmpty {
                    infoText += "Contact 2 emails: \(email2)\n"
                }
                infoText += "\nAre these the same person?"
                
                alert.informativeText = infoText
                alert.addButton(withTitle: "Yes, Same Person")
                alert.addButton(withTitle: "No, Different People")
                alert.alertStyle = .informational
                
                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
    
    // MARK: - Contact Merging
    
    private func mergeContacts(_ contacts: [CNContact]) async throws -> CNMutableContact {
        guard !contacts.isEmpty else {
            throw NSError(domain: "ContactSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "No contacts to merge"])
        }
        
        // If only one contact, return mutable copy
        if contacts.count == 1 {
            return contacts[0].mutableCopy() as! CNMutableContact
        }
        
        // Ask user how to merge
        let mergeAction = await promptMergeAction(contacts: contacts)
        
        switch mergeAction {
        case .skip:
            // Return first contact as-is
            return contacts[0].mutableCopy() as! CNMutableContact
            
        case .addMissing, .updateExisting:
            // Create merged contact with union of all data
            let merged = CNMutableContact()
            
            // Use first non-empty value for simple fields
            merged.givenName = contacts.first(where: { !$0.givenName.isEmpty })?.givenName ?? ""
            merged.familyName = contacts.first(where: { !$0.familyName.isEmpty })?.familyName ?? ""
            merged.organizationName = contacts.first(where: { !$0.organizationName.isEmpty })?.organizationName ?? ""
            merged.jobTitle = contacts.first(where: { !$0.jobTitle.isEmpty })?.jobTitle ?? ""
            //merged.note = contacts.first(where: { !$0.note.isEmpty })?.note ?? ""
            merged.birthday = contacts.first(where: { $0.birthday != nil })?.birthday
            
            // Merge phone numbers (union - keep all unique)
            var allPhones: [CNLabeledValue<CNPhoneNumber>] = []
            var phoneSet = Set<String>()
            for contact in contacts {
                for phone in contact.phoneNumbers {
                    let digits = phone.value.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    if !phoneSet.contains(digits) {
                        allPhones.append(phone)
                        phoneSet.insert(digits)
                    }
                }
            }
            merged.phoneNumbers = allPhones
            
            // Merge email addresses (union - keep all unique)
            var allEmails: [CNLabeledValue<NSString>] = []
            var emailSet = Set<String>()
            for contact in contacts {
                for email in contact.emailAddresses {
                    let emailStr = (email.value as String).lowercased()
                    if !emailSet.contains(emailStr) {
                        allEmails.append(email)
                        emailSet.insert(emailStr)
                    }
                }
            }
            merged.emailAddresses = allEmails
            
            // Merge postal addresses (union)
            var allAddresses: [CNLabeledValue<CNPostalAddress>] = []
            for contact in contacts {
                allAddresses.append(contentsOf: contact.postalAddresses)
            }
            merged.postalAddresses = allAddresses
            
            // Merge dates (union)
            var allDates: [CNLabeledValue<NSDateComponents>] = []
            for contact in contacts {
                allDates.append(contentsOf: contact.dates)
            }
            merged.dates = allDates
            
            // Merge URLs (union)
            var allUrls: [CNLabeledValue<NSString>] = []
            for contact in contacts {
                allUrls.append(contentsOf: contact.urlAddresses)
            }
            merged.urlAddresses = allUrls
            
            // Merge social profiles (union)
            var allProfiles: [CNLabeledValue<CNSocialProfile>] = []
            for contact in contacts {
                allProfiles.append(contentsOf: contact.socialProfiles)
            }
            merged.socialProfiles = allProfiles
            
            // Merge instant messages (union)
            var allIM: [CNLabeledValue<CNInstantMessageAddress>] = []
            for contact in contacts {
                allIM.append(contentsOf: contact.instantMessageAddresses)
            }
            merged.instantMessageAddresses = allIM
            
            return merged
        }
    }
    
    private func promptMergeAction(contacts: [CNContact]) async -> MergeAction {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Merge Contact Information"
                alert.informativeText = "Found \(contacts.count) duplicate records for '\(contacts[0].givenName) \(contacts[0].familyName)'.\n\nHow would you like to handle this?"
                alert.addButton(withTitle: "Add Missing Information")
                alert.addButton(withTitle: "Update Existing Information")
                alert.addButton(withTitle: "Skip")
                alert.alertStyle = .informational
                
                let response = alert.runModal()
                
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .addMissing)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .updateExisting)
                default:
                    continuation.resume(returning: .skip)
                }
            }
        }
    }
    
    enum MergeAction {
        case addMissing
        case updateExisting
        case skip
    }
    
    // MARK: - Sync to Accounts
    
    private func syncContactsToAccounts(contacts: [CNMutableContact], accounts: [ContactAccount]) async throws {
        for account in accounts {
            let saveRequest = CNSaveRequest()
            
            // Delete existing contacts in this account
            let existingContacts = try fetchContacts(from: account.container)
            for contact in existingContacts {
                let mutableContact = contact.mutableCopy() as! CNMutableContact
                saveRequest.delete(mutableContact)
            }
            
            // Add merged contacts
            for contact in contacts {
                let newContact = contact.mutableCopy() as! CNMutableContact
                saveRequest.add(newContact, toContainerWithIdentifier: account.container.identifier)
            }
            
            try contactStore.execute(saveRequest)
        }
    }
}

