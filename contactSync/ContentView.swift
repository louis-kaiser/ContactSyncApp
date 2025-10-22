// MARK: - ContentView.swift
import SwiftUI
import Contacts
import Combine

struct ContentView: View {
    @EnvironmentObject private var vm: ContactSyncViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            switch vm.authorizationStatus {
            case .notDetermined:
                VStack(alignment: .leading, spacing: 8) {
                    Text("This app needs permission to access your contacts.")
                    Button("Grant Access") {
                        Task { await vm.requestAuth() }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .denied, .restricted:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Access Denied")
                        .font(.headline)
                    Text("Please enable Contacts access in System Settings → Privacy & Security → Contacts.")
                        .fixedSize(horizontal: false, vertical: true)
                }

            default:
                accountsList
                controls
            }

            if vm.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(vm.statusMessage)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } else if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .sheet(isPresented: $vm.showMergeSheet) {
            MergeApprovalSheet()
                .environmentObject(vm)
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contact Account Sync")
                .font(.largeTitle.weight(.semibold))
            Text("Select two or more accounts to mirror a unified, merged set of contacts across all of them.")
                .foregroundStyle(.secondary)
        }
    }

    private var accountsList: some View {
        Group {
            if vm.allAccounts.isEmpty {
                Text("No contact accounts found.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    Section("Available Accounts") {
                        ForEach($vm.allAccounts) { $acct in
                            HStack {
                                Toggle(isOn: $acct.isSelected) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(acct.container.name.isEmpty ? "Unnamed Account" : acct.container.name)
                                        Text(acct.container.identifier)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await vm.beginSyncProcess() }
            } label: {
                Text("Sync")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.selectedContainerIDs.count < 2 || vm.isSyncing)

            Button {
                vm.showMergeSheet = true
            } label: {
                Text("Manual Merge")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .disabled(vm.duplicatesToMerge.isEmpty || vm.isSyncing)

            Spacer()
        }
    }
}

struct MergeApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ContactSyncViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review & Approve Merges")
                .font(.title2.weight(.semibold))
            Text("We detected \(vm.duplicatesToMerge.count) duplicate group\(vm.duplicatesToMerge.count == 1 ? "" : "s"). Approving will merge each group additively into a single “golden” contact. Nothing is deleted; new merged contacts will be created in every selected account.")
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(vm.duplicatesToMerge.enumerated()), id: \.offset) { idx, group in
                    Section("Group \(idx + 1)") {
                        ForEach(group, id: \.identifier) { contact in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces))
                                    .font(.headline)
                                if !contact.emailAddresses.isEmpty {
                                    Text(contact.emailAddresses
                                        .compactMap { ($0.value as String) }
                                        .joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Approve All & Save") {
                    Task {
                        await vm.approveAllMergesAndSave()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isSyncing)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }
}
