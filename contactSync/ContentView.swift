// MARK: - ContentView.swift
import SwiftUI
import Contacts
import Combine

struct ContentView: View {
    @StateObject private var viewModel = ContactSyncViewModel()
    @State private var showMergeApproval = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Contact Sync Manager")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            if viewModel.authorizationStatus == .notDetermined {
                authorizationView
            } else if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
                deniedView
            } else {
                mainContentView
            }
        }
        .padding(30)
        .frame(width: 600, height: 500)
        .onAppear {
            viewModel.checkAuthStatus()
        }
        .sheet(isPresented: $showMergeApproval) {
            MergeApprovalSheet(viewModel: viewModel, isPresented: $showMergeApproval)
        }
    }
    
    private var authorizationView: some View {
        VStack(spacing: 15) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Contacts Access Required")
                .font(.headline)
            
            Text("This app needs access to your contacts to perform synchronization.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Grant Access") {
                viewModel.requestAuth()
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var deniedView: some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("Access Denied")
                .font(.headline)
            
            Text("Please grant Contacts access in System Settings to use this app.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }
    
    private var mainContentView: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Select Accounts to Synchronize")
                .font(.headline)
            
            if viewModel.allAccounts.isEmpty {
                Text("Loading accounts...")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                accountsList
            }
            
            Spacer()
            
            statusSection
            
            buttonSection
        }
    }
    
    private var accountsList: some View {
        List {
            ForEach(viewModel.allAccounts.indices, id: \.self) { index in
                HStack {
                    Toggle(isOn: Binding(
                        get: { viewModel.allAccounts[index].isSelected },
                        set: { viewModel.allAccounts[index].isSelected = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.allAccounts[index].container.name)
                                .font(.body)
                            Text(viewModel.allAccounts[index].containerTypeName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(height: 250)
        .cornerRadius(8)
    }
    
    private var statusSection: some View {
        VStack(spacing: 8) {
            if viewModel.isSyncing {
                ProgressView()
                    .scaleEffect(0.8)
            }
            
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(viewModel.statusIsError ? .red : .secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(height: 40)
    }
    
    private var buttonSection: some View {
        HStack(spacing: 12) {
            Button("Sync Contacts") {
                Task {
                    await viewModel.beginSyncProcess()
                    if !viewModel.duplicatesToMerge.isEmpty {
                        showMergeApproval = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedAccounts.count < 2 || viewModel.isSyncing)
            
            if !viewModel.duplicatesToMerge.isEmpty && !viewModel.isSyncing {
                Button("Review Merges (\(viewModel.duplicatesToMerge.count))") {
                    showMergeApproval = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - MergeApprovalSheet.swift
struct MergeApprovalSheet: View {
    @ObservedObject var viewModel: ContactSyncViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Duplicate Contacts Found")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("The following contact groups have been identified as duplicates. Review and approve to merge them.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            List {
                ForEach(viewModel.duplicatesToMerge.indices, id: \.self) { groupIndex in
                    Section(header: Text("Duplicate Group \(groupIndex + 1)")) {
                        ForEach(viewModel.duplicatesToMerge[groupIndex], id: \.identifier) { contact in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(contact.givenName) \(contact.familyName)")
                                    .font(.headline)
                                
                                if let email = contact.emailAddresses.first {
                                    Text(email.value as String)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                if let containerID = viewModel.contactToContainerMap[contact.identifier] {
                                    Text("From: \(containerID)")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(height: 300)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.duplicatesToMerge = []
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Approve All & Merge") {
                    Task {
                        await viewModel.performApprovedMerge()
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 600, height: 550)
    }
}

// MARK: - ContactSyncViewModel.swift
import SwiftUI
import Contacts

struct SelectableAccount: Identifiable {
    let id = UUID()
    let container: CNContainer
    var isSelected: Bool = false
    
    var containerTypeName: String {
        // CNContainer doesn't expose type in macOS, so we use identifier patterns
        let identifier = container.identifier.lowercased()
        if identifier.contains("icloud") {
            return "iCloud"
        } else if identifier.contains("exchange") {
            return "Exchange"
        } else if identifier.contains("google") || identifier.contains("gmail") {
            return "Google"
        } else if identifier.contains("carddav") {
            return "CardDAV"
        } else if identifier.contains("local") {
            return "Local"
        } else {
            return "Account"
        }
    }
}

@MainActor
class ContactSyncViewModel: ObservableObject {
    @Published var contactStore = CNContactStore()
    @Published var allAccounts: [SelectableAccount] = []
    @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined
    @Published var duplicatesToMerge: [[CNContact]] = []
    @Published var isSyncing: Bool = false
    @Published var statusMessage: String = ""
    @Published var statusIsError: Bool = false
    @Published var contactToContainerMap: [String: String] = [:]
    
    private var safeToSyncContacts: [CNContact] = []
    
    var selectedAccounts: [CNContainer] {
        allAccounts.filter { $0.isSelected }.map { $0.container }
    }
    
    // MARK: - Authorization
    
    func checkAuthStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        if authorizationStatus == .authorized {
            fetchAccounts()
        }
    }
    
    func requestAuth() {
        Task {
            do {
                let granted = try await contactStore.requestAccess(for: .contacts)
                authorizationStatus = granted ? .authorized : .denied
                if granted {
                    fetchAccounts()
                }
            } catch {
                statusMessage = "Authorization error: \(error.localizedDescription)"
                statusIsError = true
            }
        }
    }
    
    // MARK: - Account Fetching
    
    func fetchAccounts() {
        do {
            let containers = try contactStore.containers(matching: nil)
            allAccounts = containers.map { SelectableAccount(container: $0) }
            statusMessage = "Found \(allAccounts.count) account(s)"
            statusIsError = false
        } catch {
            statusMessage = "Error fetching accounts: \(error.localizedDescription)"
            statusIsError = true
        }
    }
    
    // MARK: - Sync Process
    
    func beginSyncProcess() async {
        isSyncing = true
        statusMessage = "Fetching contacts from selected accounts..."
        statusIsError = false
        duplicatesToMerge = []
        safeToSyncContacts = []
        contactToContainerMap = [:]
        
        do {
            // Fetch all contacts from selected containers
            var allContacts: [CNContact] = []
            
            for container in selectedAccounts {
                let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
                let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: fetchKeys)
                
                // Track which container each contact came from
                for contact in contacts {
                    contactToContainerMap[contact.identifier] = container.name
                }
                
                allContacts.append(contentsOf: contacts)
            }
            
            statusMessage = "Analyzing \(allContacts.count) contacts for duplicates..."
            
            // Detect duplicates
            let (duplicates, unique) = detectDuplicates(in: allContacts)
            
            duplicatesToMerge = duplicates
            safeToSyncContacts = unique
            
            if duplicates.isEmpty {
                statusMessage = "No duplicates found. Syncing \(unique.count) contacts..."
                await saveAllContacts(contacts: unique)
            } else {
                statusMessage = "Found \(duplicates.count) duplicate group(s). Review merges to continue."
                statusIsError = false
            }
            
        } catch {
            statusMessage = "Sync error: \(error.localizedDescription)"
            statusIsError = true
        }
        
        isSyncing = false
    }
    
    func performApprovedMerge() async {
        isSyncing = true
        statusMessage = "Merging approved duplicates..."
        
        var mergedContacts: [CNContact] = []
        
        // Merge each group
        for group in duplicatesToMerge {
            let merged = performMerge(for: group)
            mergedContacts.append(merged)
        }
        
        // Combine merged + safe contacts
        let allContactsToSync = mergedContacts + safeToSyncContacts
        
        statusMessage = "Saving \(allContactsToSync.count) contacts to all selected accounts..."
        await saveAllContacts(contacts: allContactsToSync)
        
        duplicatesToMerge = []
        isSyncing = false
    }
    
    // MARK: - Duplicate Detection
    
    private func detectDuplicates(in contacts: [CNContact]) -> ([[CNContact]], [CNContact]) {
        var contactsByKey: [String: [CNContact]] = [:]
        
        // Group contacts by name+email key
        for contact in contacts {
            let name = "\(contact.givenName.lowercased())|\(contact.familyName.lowercased())"
            
            if !contact.emailAddresses.isEmpty {
                for email in contact.emailAddresses {
                    let emailKey = (email.value as String).lowercased()
                    let key = "\(name)|\(emailKey)"
                    contactsByKey[key, default: []].append(contact)
                }
            }
        }
        
        // Find groups with duplicates (2+ contacts with same key)
        var duplicateGroups: [[CNContact]] = []
        var processedIdentifiers = Set<String>()
        
        for (_, group) in contactsByKey {
            if group.count > 1 {
                // Ensure we haven't already processed these contacts
                let identifiers = Set(group.map { $0.identifier })
                if identifiers.isDisjoint(with: processedIdentifiers) {
                    duplicateGroups.append(group)
                    processedIdentifiers.formUnion(identifiers)
                }
            }
        }
        
        // Find unique contacts (not in any duplicate group)
        let duplicateIdentifiers = Set(duplicateGroups.flatMap { $0.map { $0.identifier } })
        let uniqueContacts = contacts.filter { !duplicateIdentifiers.contains($0.identifier) }
        
        return (duplicateGroups, uniqueContacts)
    }
    
    // MARK: - Merge Logic (Additive)
    
    func performMerge(for group: [CNContact]) -> CNMutableContact {
        guard let first = group.first else {
            return CNMutableContact()
        }
        
        let merged = first.mutableCopy() as! CNMutableContact
        
        // For each subsequent contact, add unique information
        for contact in group.dropFirst() {
            mergePhoneNumbers(from: contact, into: merged)
            mergeEmails(from: contact, into: merged)
            mergeAddresses(from: contact, into: merged)
            mergeURLs(from: contact, into: merged)
            mergeDates(from: contact, into: merged)
            mergeSocialProfiles(from: contact, into: merged)
            mergeInstantMessages(from: contact, into: merged)
            
            // Merge simple fields if missing
            if merged.nickname.isEmpty && !contact.nickname.isEmpty {
                merged.nickname = contact.nickname
            }
            if merged.organizationName.isEmpty && !contact.organizationName.isEmpty {
                merged.organizationName = contact.organizationName
            }
            if merged.jobTitle.isEmpty && !contact.jobTitle.isEmpty {
                merged.jobTitle = contact.jobTitle
            }
            
            // Merge notes - only if we have the key fetched
            if contact.areKeysAvailable([CNContactNoteKey as CNKeyDescriptor]) {
                if merged.note.isEmpty && !contact.note.isEmpty {
                    merged.note = contact.note
                } else if !contact.note.isEmpty && !merged.note.contains(contact.note) {
                    merged.note = merged.note + "\n" + contact.note
                }
            }
        }
        
        return merged
    }
    
    // Merge helpers for labeled values - only add if unique
    
    private func mergePhoneNumbers(from source: CNContact, into target: CNMutableContact) {
        for phone in source.phoneNumbers {
            if !target.phoneNumbers.contains(where: { existing in
                existing.label == phone.label && existing.value.stringValue == phone.value.stringValue
            }) {
                target.phoneNumbers.append(phone)
            }
        }
    }
    
    private func mergeEmails(from source: CNContact, into target: CNMutableContact) {
        for email in source.emailAddresses {
            if !target.emailAddresses.contains(where: { existing in
                existing.label == email.label && (existing.value as String).lowercased() == (email.value as String).lowercased()
            }) {
                target.emailAddresses.append(email)
            }
        }
    }
    
    private func mergeAddresses(from source: CNContact, into target: CNMutableContact) {
        for address in source.postalAddresses {
            if !target.postalAddresses.contains(where: { $0.value.isEqual(address.value) }) {
                target.postalAddresses.append(address)
            }
        }
    }
    
    private func mergeURLs(from source: CNContact, into target: CNMutableContact) {
        for url in source.urlAddresses {
            if !target.urlAddresses.contains(where: { existing in
                (existing.value as String).lowercased() == (url.value as String).lowercased()
            }) {
                target.urlAddresses.append(url)
            }
        }
    }
    
    private func mergeDates(from source: CNContact, into target: CNMutableContact) {
        for dateComponent in source.dates {
            // DateComponents comparison: check if same day exists
            let isDuplicate = target.dates.contains(where: { existing in
                existing.label == dateComponent.label &&
                existing.value.day == dateComponent.value.day &&
                existing.value.month == dateComponent.value.month &&
                existing.value.year == dateComponent.value.year
            })
            
            if !isDuplicate {
                target.dates.append(dateComponent)
            }
        }
    }
    
    private func mergeSocialProfiles(from source: CNContact, into target: CNMutableContact) {
        for profile in source.socialProfiles {
            if !target.socialProfiles.contains(where: { existing in
                existing.value.service == profile.value.service && existing.value.username == profile.value.username
            }) {
                target.socialProfiles.append(profile)
            }
        }
    }
    
    private func mergeInstantMessages(from source: CNContact, into target: CNMutableContact) {
        for im in source.instantMessageAddresses {
            if !target.instantMessageAddresses.contains(where: { existing in
                existing.value.service == im.value.service && existing.value.username == im.value.username
            }) {
                target.instantMessageAddresses.append(im)
            }
        }
    }
    
    // MARK: - Save Contacts
    
    private func saveAllContacts(contacts: [CNContact]) async {
        do {
            // Save to each selected container
            for container in selectedAccounts {
                let saveRequest = CNSaveRequest()
                
                for contact in contacts {
                    let mutableContact = contact.mutableCopy() as! CNMutableContact
                    saveRequest.add(mutableContact, toContainerWithIdentifier: container.identifier)
                }
                
                try contactStore.execute(saveRequest)
            }
            
            statusMessage = "Sync complete! \(contacts.count) contact(s) saved to \(selectedAccounts.count) account(s)."
            statusIsError = false
        } catch {
            statusMessage = "Save error: \(error.localizedDescription)"
            statusIsError = true
        }
    }
    
    // MARK: - Fetch Keys
    
    private var fetchKeys: [CNKeyDescriptor] {
        // Note: CNContactNoteKey requires com.apple.developer.contacts.notes entitlement
        // Omitting it to avoid runtime crashes on apps without the entitlement
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactPostalAddressesKey,
            CNContactUrlAddressesKey,
            CNContactDatesKey,
            CNContactSocialProfilesKey,
            CNContactInstantMessageAddressesKey
        ] as [CNKeyDescriptor]
    }
}

// MARK: - Entitlements Note
/*
 To enable notes synchronization, add this entitlement to your app:
 
 In your .entitlements file:
 <key>com.apple.developer.contacts.notes</key>
 <true/>
 
 Then uncomment CNContactNoteKey in the fetchKeys array above.
 */
