// MARK: - Content View
import SwiftUI
import Contacts
import Combine

struct ContentView: View {
    @StateObject private var synchronizer = ContactSynchronizer()
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("Contact Account Synchronizer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Select accounts to synchronize")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Authorization Status
            if synchronizer.authorizationStatus != .authorized {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("Contacts Access Required")
                        .font(.headline)
                    
                    Text("This app needs access to your contacts to synchronize accounts.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    
                    Button("Request Access") {
                        Task {
                            await synchronizer.requestAccess()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                // Account List
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if synchronizer.accounts.isEmpty {
                            Text("No accounts found")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            ForEach(Array(synchronizer.accounts.enumerated()), id: \.offset) { index, account in
                                HStack {
                                    Toggle(isOn: Binding(
                                        get: { synchronizer.accounts[index].isSelected },
                                        set: { synchronizer.accounts[index].isSelected = $0 }
                                    )) {
                                        VStack(alignment: .leading) {
                                            Text(account.name)
                                                .font(.headline)
                                        }
                                    }
                                    .toggleStyle(.switch)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 300)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                
                // Sync Button
                Button(action: {
                    Task {
                        await synchronizer.synchronizeSelectedAccounts()
                    }
                }) {
                    HStack {
                        if synchronizer.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Synchronize Selected Accounts")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(synchronizer.isLoading || synchronizer.accounts.filter { $0.isSelected }.count < 2)
                .controlSize(.large)
            }
            
            // Status Message
            if !synchronizer.statusMessage.isEmpty {
                Text(synchronizer.statusMessage)
                    .font(.callout)
                    .foregroundColor(synchronizer.statusMessage.hasPrefix("✓") ? .green : .primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if synchronizer.authorizationStatus == .authorized {
                await synchronizer.loadAccounts()
            }
        }
    }
}

// MARK: - Extensions

extension CNContainerType {
    var displayName: String {
        switch self {
        case .local: return "Local"
        case .exchange: return "Exchange"
        case .cardDAV: return "CardDAV"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .frame(width: 600, height: 500)
}

