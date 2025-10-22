import Foundation
import SwiftUI
import Contacts
import Combine

// MARK: - View Model

@MainActor
final class ContactSyncViewModel: ObservableObject {

    // MARK: Published UI State

    @Published var contactStore = CNContactStore()
    @Published var allAccounts: [SelectableAccount] = []
    @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined

    /// Duplicate groups awaiting manual approval; each inner array is one group.
    @Published var duplicatesToMerge: [[CNContact]] = []
    /// Contacts with no duplicates in the selected accounts.
    @Published var safeToSync: [CNContact] = []

    @Published var isSyncing: Bool = false
    @Published var statusMessage: String = ""
    @Published var showMergeSheet: Bool = false

    // MARK: Derived

    var selectedContainerIDs: [String] {
        allAccounts.filter { $0.isSelected }.map { $0.container.identifier }
    }

    // MARK: Lifecycle / Permissions

    func checkAuthStatus() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAuth() async {
        do {
            let granted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                contactStore.requestAccess(for: .contacts) { granted, err in
                    if let err { cont.resume(throwing: err) } else { cont.resume(returning: granted) }
                }
            }
            authorizationStatus = granted ? .authorized : .denied
            if granted { fetchAccounts() }
        } catch {
            authorizationStatus = .denied
            statusMessage = "Failed to request access: \(error.localizedDescription)"
        }
    }

    func fetchAccounts() {
        do {
            let containers = try contactStore.containers(matching: nil)
            allAccounts = containers.map { SelectableAccount(container: $0, isSelected: false) }
            statusMessage = allAccounts.isEmpty ? "No accounts were found." : ""
        } catch {
            statusMessage = "Could not fetch accounts: \(error.localizedDescription)"
        }
    }

    // MARK: Sync Orchestration

    /// Master entry-point from the "Sync" button. This fetches and analyzes contacts
    /// and prepares duplicate groups for manual approval. If no duplicates are found,
    /// it saves the "safe-to-sync" set immediately.
    func beginSyncProcess() async {
        guard authorizationStatus == .authorized else {
            statusMessage = "Contacts access is required."
            return
        }
        guard selectedContainerIDs.count >= 2 else {
            statusMessage = "Select at least two accounts to sync."
            return
        }

        isSyncing = true
        statusMessage = "Fetching contacts…"

        do {
            // 1) Fetch raw (non-unified) contacts across the store; attach each to its container.
            let fetched = try await fetchContactsForSelectedContainers()

            // 2) Analyze for duplicates (strict definition) and compute safe set.
            statusMessage = "Analyzing duplicates…"
            let (dupeGroups, safe) = groupDuplicatesAndSafe(contacts: fetched)

            self.duplicatesToMerge = dupeGroups
            self.safeToSync = safe

            if dupeGroups.isEmpty {
                // No manual approval needed; persist the safe set immediately.
                statusMessage = "No duplicates found. Saving contacts…"
                try await saveContactsToAllSelected(accounts: selectedContainerIDs,
                                                    contacts: safe)
                statusMessage = "Sync complete."
            } else {
                statusMessage = "Found \(dupeGroups.count) duplicate group\(dupeGroups.count == 1 ? "" : "s"). Review and approve to continue."
                showMergeSheet = true
            }
        } catch {
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }

        isSyncing = false
    }

    /// Called by the sheet's "Approve All & Save".
    func approveAllMergesAndSave() async {
        guard !isSyncing else { return }
        guard authorizationStatus == .authorized else {
            statusMessage = "Contacts access is required."
            return
        }
        guard selectedContainerIDs.count >= 2 else {
            statusMessage = "Select at least two accounts to sync."
            return
        }

        isSyncing = true
        statusMessage = "Merging duplicates…"

        do {
            // 1) Produce golden contacts for each duplicate group.
            let mergedGoldens: [CNMutableContact] = duplicatesToMerge.map { performMerge(for: $0) }

            // 2) Persist golden + safe-to-sync into each selected container.
            statusMessage = "Saving to \(selectedContainerIDs.count) accounts…"
            let contactsToSave: [CNContact] = mergedGoldens + safeToSync
            try await saveContactsToAllSelected(accounts: selectedContainerIDs,
                                                contacts: contactsToSave)

            // 3) Clean state.
            duplicatesToMerge.removeAll()
            safeToSync.removeAll()
            statusMessage = "Sync complete."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }

        isSyncing = false
    }

    // MARK: Fetching

    /// Returns all non-unified contacts for the selected containers, each paired with its container ID.
    private func fetchContactsForSelectedContainers() async throws -> [FetchedContact] {
        // Fetch non-unified results so duplicates across accounts are not pre-unified by the system.
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor
        ]

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var results: [FetchedContact] = []
                do {
                    let req = CNContactFetchRequest(keysToFetch: keys)
                    req.unifyResults = false // CRITICAL: fetch raw records across containers

                    try self.contactStore.enumerateContacts(with: req) { contact, _ in
                        // Resolve the container of this raw contact.
                        // This is efficient enough in practice; we could cache if needed.
                        let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: contact.identifier)
                        if let container = try? self.contactStore.containers(matching: predicate).first,
                           self.selectedContainerIDs.contains(container.identifier) {
                            results.append(FetchedContact(contact: contact, containerID: container.identifier))
                        }
                    }
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Duplicate Analysis

    /// Groups duplicates by (full name, shared email across different accounts) and returns (duplicate groups, safe contacts).
    /// Algorithm notes:
    /// - Within a name bucket (exact given+family match, case-insensitive), we build edges between any two contacts
    ///   that share at least one identical email (case-insensitive) and come from different containers.
    /// - Connected components of size ≥ 2 with ≥ 2 distinct container IDs form duplicate groups.
    private func groupDuplicatesAndSafe(contacts: [FetchedContact]) -> (dupes: [[CNContact]], safe: [CNContact]) {
        // Bucket by strict full name (given + family).
        let buckets = Dictionary(grouping: contacts) { (fc: FetchedContact) -> String in
            let g = fc.contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let f = fc.contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return g + "||" + f
        }

        var duplicateGroups: [[CNContact]] = []
        var seenAsDuplicate = Set<String>() // CNContact.identifier

        for (_, group) in buckets {
            guard group.count >= 2 else { continue }

            // Index mapping for union-find within this bucket
            let n = group.count
            var uf = UnionFind(count: n)

            // Map email -> indices with that email
            var emailMap: [String: [Int]] = [:]
            for (i, fc) in group.enumerated() {
                let emails = fc.contact.emailAddresses.compactMap { ($0.value as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                for e in Set(emails) { // de-dup per contact
                    emailMap[e, default: []].append(i)
                }
            }

            // Connect indices that share an email and belong to different containers.
            for (_, idxs) in emailMap {
                if idxs.count < 2 { continue }
                // For each pair in indices: union if containers differ.
                for i in 0..<idxs.count {
                    for j in (i+1)..<idxs.count {
                        if group[idxs[i]].containerID != group[idxs[j]].containerID {
                            uf.union(idxs[i], idxs[j])
                        }
                    }
                }
            }

            // Build components.
            let comps = uf.components()
            for comp in comps {
                guard comp.count >= 2 else { continue }
                let distinctContainers = Set(comp.map { group[$0].containerID })
                guard distinctContainers.count >= 2 else { continue }

                let contactsComp = comp.map { group[$0].contact }
                duplicateGroups.append(contactsComp)
                for c in contactsComp { seenAsDuplicate.insert(c.identifier) }
            }
        }

        // Safe = all contacts that were not captured in any duplicate component.
        let safe = contacts
            .filter { !seenAsDuplicate.contains($0.contact.identifier) }
            .map { $0.contact }

        return (duplicateGroups, safe)
    }

    // MARK: Merge Engine (Additive)

    /// Produces a “golden” contact by copying the first and additively appending unique labeled values
    /// from the rest. Singular fields are kept from the first unless empty, in which case they’re filled.
    func performMerge(for group: [CNContact]) -> CNMutableContact {
        precondition(!group.isEmpty, "Group must not be empty")
        let base = group[0]
        let golden = mutableClone(of: base)

        // Helper to fill singular fields if missing on golden.
        func fillIfEmpty(_ apply: () -> Void, isEmpty: Bool) {
            if isEmpty { apply() }
        }

        for contact in group.dropFirst() {
            var c = contact // shorthand

            // Additive unique merges for labeled values (dedup by label+value semantics).
            golden.phoneNumbers = addUniquePhoneNumbers(existing: golden.phoneNumbers, incoming: c.phoneNumbers)
            golden.emailAddresses = addUniqueEmails(existing: golden.emailAddresses, incoming: c.emailAddresses)
            golden.postalAddresses = addUniquePostal(existing: golden.postalAddresses, incoming: c.postalAddresses)
            golden.urlAddresses = addUniqueURLs(existing: golden.urlAddresses, incoming: c.urlAddresses)
            golden.socialProfiles = addUniqueSocial(existing: golden.socialProfiles, incoming: c.socialProfiles)
            golden.instantMessageAddresses = addUniqueIM(existing: golden.instantMessageAddresses, incoming: c.instantMessageAddresses)
            golden.dates = addUniqueDates(existing: golden.dates, incoming: c.dates)

            // Singular fields: keep base if present; otherwise fill from others.
            if golden.middleName.isEmpty, !c.middleName.isEmpty { golden.middleName = c.middleName }
            if golden.organizationName.isEmpty, !c.organizationName.isEmpty { golden.organizationName = c.organizationName }
            if golden.departmentName.isEmpty, !c.departmentName.isEmpty { golden.departmentName = c.departmentName }
            if golden.jobTitle.isEmpty, !c.jobTitle.isEmpty { golden.jobTitle = c.jobTitle }

            if golden.birthday == nil, let b = c.birthday { golden.birthday = b }

            // Image: prefer base if present; otherwise take first non-empty.
            if golden.imageData == nil, let img = c.imageData { golden.imageData = img }

            // Notes: append unique snippets (very light approach to avoid bloat).
            let trimmedGolden = golden.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedIncoming = c.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedIncoming.isEmpty, !trimmedGolden.contains(trimmedIncoming) {
                golden.note = trimmedGolden.isEmpty ? trimmedIncoming : "\(trimmedGolden) | \(trimmedIncoming)"
            }
        }

        return golden
    }

    // MARK: Saving

    /// Saves all provided contacts into **each** selected account by creating new contacts per account.
    /// Note: We create a fresh CNMutableContact per container to avoid reusing the same instance in a request.
    private func saveContactsToAllSelected(accounts containerIDs: [String], contacts: [CNContact]) async throws {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let save = CNSaveRequest()
                    for c in contacts {
                        for containerID in containerIDs {
                            let mutable = (c as? CNMutableContact) ?? self.mutableClone(of: c)
                            save.add(mutable, toContainerWithIdentifier: containerID)
                        }
                    }
                    try self.contactStore.execute(save)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Utilities (Cloning & Dedup Helpers)

    private func mutableClone(of contact: CNContact) -> CNMutableContact {
        // Copy all supported fields.
        let m = CNMutableContact()
        m.givenName = contact.givenName
        m.familyName = contact.familyName
        m.middleName = contact.middleName
        m.organizationName = contact.organizationName
        m.departmentName = contact.departmentName
        m.jobTitle = contact.jobTitle
        m.phoneNumbers = contact.phoneNumbers
        m.emailAddresses = contact.emailAddresses
        m.postalAddresses = contact.postalAddresses
        m.urlAddresses = contact.urlAddresses
        m.socialProfiles = contact.socialProfiles
        m.instantMessageAddresses = contact.instantMessageAddresses
        m.dates = contact.dates
        m.birthday = contact.birthday
        //m.note = contact.note
        /*
         Problem with sync notes
         */
        m.imageData = contact.imageData
        return m
    }

    private func addUniquePhoneNumbers(
        existing: [CNLabeledValue<CNPhoneNumber>],
        incoming: [CNLabeledValue<CNPhoneNumber>]
    ) -> [CNLabeledValue<CNPhoneNumber>] {
        var result = existing
        for val in incoming {
            let isDup = result.contains { $0.label == val.label && $0.value.stringValue == val.value.stringValue }
            if !isDup { result.append(val) }
        }
        return result
    }

    private func addUniqueEmails(
        existing: [CNLabeledValue<NSString>],
        incoming: [CNLabeledValue<NSString>]
    ) -> [CNLabeledValue<NSString>] {
        var result = existing
        for val in incoming {
            let v = (val.value as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let isDup = result.contains {
                $0.label == val.label &&
                ((($0.value as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) == v)
            }
            if !isDup { result.append(val) }
        }
        return result
    }

    private func addUniquePostal(
        existing: [CNLabeledValue<CNPostalAddress>],
        incoming: [CNLabeledValue<CNPostalAddress>]
    ) -> [CNLabeledValue<CNPostalAddress>] {
        func stringify(_ a: CNPostalAddress) -> String {
            "\(a.street)|\(a.city)|\(a.state)|\(a.postalCode)|\(a.country)|\(a.isoCountryCode)"
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = existing
        for val in incoming {
            let key = stringify(val.value)
            let isDup = result.contains { $0.label == val.label && stringify($0.value) == key }
            if !isDup { result.append(val) }
        }
        return result
    }

    private func addUniqueURLs(
        existing: [CNLabeledValue<NSString>],
        incoming: [CNLabeledValue<NSString>]
    ) -> [CNLabeledValue<NSString>] {
        var result = existing
        for val in incoming {
            let v = (val.value as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let isDup = result.contains {
                $0.label == val.label &&
                ((($0.value as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) == v)
            }
            if !isDup { result.append(val) }
        }
        return result
    }

    private func addUniqueSocial(
        existing: [CNLabeledValue<CNSocialProfile>],
        incoming: [CNLabeledValue<CNSocialProfile>]
    ) -> [CNLabeledValue<CNSocialProfile>] {
        func key(_ p: CNSocialProfile) -> String {
            "\(p.service ?? "")|\(p.username ?? "")|\(p.urlString ?? "")"
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = existing
        for val in incoming {
            let k = key(val.value)
            let isDup = result.contains { $0.label == val.label && key($0.value) == k }
            if !isDup { result.append(val) }
        }
        return result
    }

    private func addUniqueIM(
        existing: [CNLabeledValue<CNInstantMessageAddress>],
        incoming: [CNLabeledValue<CNInstantMessageAddress>]
    ) -> [CNLabeledValue<CNInstantMessageAddress>] {
        func key(_ a: CNInstantMessageAddress) -> String {
            "\(a.service ?? "")|\(a.username ?? "")"
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = existing
        for val in incoming {
            let k = key(val.value)
            let isDup = result.contains { $0.label == val.label && key($0.value) == k }
            if !isDup { result.append(val) }
        }
        return result
    }

    private func addUniqueDates(
        existing: [CNLabeledValue<NSDateComponents>],
        incoming: [CNLabeledValue<NSDateComponents>]
    ) -> [CNLabeledValue<NSDateComponents>] {
        func key(_ d: NSDateComponents) -> String {
            let dc = d as DateComponents
            return "\(dc.era ?? -1)|\(dc.year ?? -1)|\(dc.month ?? -1)|\(dc.day ?? -1)|\(dc.hour ?? -1)|\(dc.minute ?? -1)"
        }
        var result = existing
        for val in incoming {
            let k = key(val.value)
            let isDup = result.contains { $0.label == val.label && key($0.value) == k }
            if !isDup { result.append(val) }
        }
        return result
    }
}

// MARK: - Models

struct SelectableAccount: Identifiable, Hashable {
    var id: String { container.identifier }
    let container: CNContainer
    var isSelected: Bool
}

struct FetchedContact {
    let contact: CNContact
    let containerID: String
}

// MARK: - Union-Find (Disjoint Set)
// Used to find connected components of duplicates within a name bucket.
// Two contacts are connected if they share ≥1 identical email AND come from different containers.

private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x]) // path compression
        }
        return parent[x]
    }

    mutating func union(_ x: Int, _ y: Int) {
        var rx = find(x)
        var ry = find(y)
        if rx == ry { return }
        if rank[rx] < rank[ry] {
            swap(&rx, &ry)
        }
        parent[ry] = rx
        if rank[rx] == rank[ry] {
            rank[rx] += 1
        }
    }

    func components() -> [[Int]] {
        var groups: [Int: [Int]] = [:]
        for i in 0..<parent.count {
            let r = findNoPathCompression(i)
            groups[r, default: []].append(i)
        }
        return Array(groups.values)
    }

    // A non-mutating find for use in components() to keep value semantics simple.
    private func findNoPathCompression(_ x: Int) -> Int {
        var x = x
        var p = parent
        while p[x] != x { x = p[x] }
        return x
    }
}

