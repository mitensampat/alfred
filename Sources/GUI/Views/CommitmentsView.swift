import SwiftUI

struct CommitmentsView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var selectedTab: CommitmentTab = .all
    @State private var commitments: [Commitment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingScanSheet = false

    enum CommitmentTab: String, CaseIterable {
        case all = "All"
        case iOwe = "I Owe"
        case theyOwe = "They Owe"
        case overdue = "Overdue"

        var icon: String {
            switch self {
            case .all: return "list.bullet"
            case .iOwe: return "arrow.up.circle"
            case .theyOwe: return "arrow.down.circle"
            case .overdue: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        ZStack {
            SlackTheme.surfaceBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with back button
                headerView
                    .padding(.vertical, SlackTheme.paddingSmall)
                    .background(SlackTheme.primaryBackground)

                // Tab selector
                tabSelector
                    .padding(.horizontal, SlackTheme.paddingSmall)
                    .padding(.vertical, SlackTheme.paddingSmall)

                // Content
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else {
                    commitmentsList
                }

                Spacer()

                // Scan button at bottom
                scanButton
                    .padding(SlackTheme.paddingSmall)
            }
        }
        .onAppear {
            loadCommitments()
        }
        .sheet(isPresented: $showingScanSheet) {
            CommitmentScanView(viewModel: viewModel) {
                loadCommitments()
            }
        }
    }

    private var headerView: some View {
        HStack {
            Button(action: {
                viewModel.navigateBack()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(SlackTheme.inverseText)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            VStack(spacing: 2) {
                Text("COMMITMENTS")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SlackTheme.inverseText)

                if !commitments.isEmpty {
                    Text("\(commitments.count) total")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(SlackTheme.inverseText.opacity(0.7))
                }
            }

            Spacer()

            // Refresh button
            Button(action: loadCommitments) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SlackTheme.inverseText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, SlackTheme.paddingSmall)
    }

    private var tabSelector: some View {
        HStack(spacing: SlackTheme.paddingSmall) {
            ForEach(CommitmentTab.allCases, id: \.self) { tab in
                TabButton(
                    title: tab.rawValue,
                    icon: tab.icon,
                    isSelected: selectedTab == tab,
                    badge: badgeCount(for: tab)
                ) {
                    selectedTab = tab
                }
            }
        }
    }

    private var commitmentsList: some View {
        ScrollView {
            VStack(spacing: SlackTheme.paddingSmall) {
                if filteredCommitments.isEmpty {
                    emptyStateView
                } else {
                    ForEach(filteredCommitments) { commitment in
                        CommitmentCard(commitment: commitment)
                            .onTapGesture {
                                // TODO: Navigate to detail view
                            }
                    }
                }
            }
            .padding(SlackTheme.paddingSmall)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: SlackTheme.accentPrimary))
            Text("Loading commitments...")
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(SlackTheme.accentDanger)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                loadCommitments()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedTab == .overdue ? "checkmark.circle" : "tray")
                .font(.system(size: 32))
                .foregroundColor(SlackTheme.tertiaryText)
            Text(emptyStateMessage)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanButton: some View {
        Button(action: {
            showingScanSheet = true
        }) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                Text("Scan for Commitments")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(SlackTheme.accentPrimary)
            .cornerRadius(SlackTheme.cornerRadiusSmall)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Helper Functions

    private var filteredCommitments: [Commitment] {
        switch selectedTab {
        case .all:
            return commitments
        case .iOwe:
            return commitments.filter { $0.type == .iOwe }
        case .theyOwe:
            return commitments.filter { $0.type == .theyOwe }
        case .overdue:
            return commitments.filter { $0.isOverdue }
        }
    }

    private func badgeCount(for tab: CommitmentTab) -> Int? {
        let count: Int
        switch tab {
        case .all:
            return nil // Don't show badge for "All"
        case .iOwe:
            count = commitments.filter { $0.type == .iOwe }.count
        case .theyOwe:
            count = commitments.filter { $0.type == .theyOwe }.count
        case .overdue:
            count = commitments.filter { $0.isOverdue }.count
        }
        return count > 0 ? count : nil
    }

    private var emptyStateMessage: String {
        switch selectedTab {
        case .all:
            return "No commitments found.\nScan messages to get started!"
        case .iOwe:
            return "You don't owe anyone right now.\nGreat job staying on top of things!"
        case .theyOwe:
            return "No one owes you anything.\nAll caught up!"
        case .overdue:
            return "No overdue commitments.\nYou're doing great!"
        }
    }

    private func loadCommitments() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loaded = try await viewModel.alfredService.fetchCommitments()
                await MainActor.run {
                    self.commitments = loaded
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load commitments: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Tab Button Component
struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? SlackTheme.accentPrimary : SlackTheme.tertiaryText)

                    if let count = badge {
                        Text("\(count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(SlackTheme.accentDanger)
                            .cornerRadius(6)
                            .offset(x: 8, y: -8)
                    }
                }

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? SlackTheme.accentPrimary : SlackTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? SlackTheme.accentPrimary.opacity(0.1) : Color.clear)
            .cornerRadius(SlackTheme.cornerRadiusSmall)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Commitment Card Component
struct CommitmentCard: View {
    let commitment: Commitment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                Image(systemName: commitment.type == .iOwe ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(commitment.type == .iOwe ? SlackTheme.accentWarning : SlackTheme.accentSuccess)

                Text(commitment.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SlackTheme.primaryText)
                    .lineLimit(2)

                Spacer()

                if commitment.isOverdue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(SlackTheme.accentDanger)
                }
            }

            // Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(commitment.type == .iOwe ? "From me →" : "From \(commitment.committedBy) →")
                        .font(.system(size: 11))
                        .foregroundColor(SlackTheme.secondaryText)
                    Text(commitment.type == .iOwe ? commitment.committedTo : "me")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(SlackTheme.primaryText)
                }

                HStack(spacing: 8) {
                    Label(commitment.sourcePlatform.displayName, systemImage: "message")
                        .font(.system(size: 10))
                        .foregroundColor(SlackTheme.tertiaryText)

                    if let dueDate = commitment.dueDate {
                        Label(formatDate(dueDate), systemImage: "calendar")
                            .font(.system(size: 10))
                            .foregroundColor(commitment.isOverdue ? SlackTheme.accentDanger : SlackTheme.tertiaryText)
                    }

                    Spacer()

                    Text(commitment.priority.emoji)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(SlackTheme.paddingSmall)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Button Style
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(SlackTheme.accentPrimary)
            .cornerRadius(SlackTheme.cornerRadiusSmall)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
