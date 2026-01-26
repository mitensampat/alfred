import SwiftUI

struct DraftsView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var drafts: [MessageDraft] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingClearConfirmation = false

    var body: some View {
        ZStack {
            SlackTheme.surfaceBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with back button
                headerView
                    .padding(.vertical, SlackTheme.paddingSmall)
                    .background(SlackTheme.primaryBackground)

                // Content
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else if drafts.isEmpty {
                    emptyStateView
                } else {
                    draftsList
                }

                Spacer()
            }
        }
        .onAppear {
            loadDrafts()
        }
        .alert(isPresented: $showingClearConfirmation) {
            Alert(
                title: Text("Clear All Drafts"),
                message: Text("Are you sure you want to delete all \(drafts.count) draft(s)?"),
                primaryButton: .destructive(Text("Clear All")) {
                    clearAllDrafts()
                },
                secondaryButton: .cancel()
            )
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
                Text("MESSAGE DRAFTS")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SlackTheme.inverseText)

                if !drafts.isEmpty {
                    Text("\(drafts.count) draft\(drafts.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(SlackTheme.inverseText.opacity(0.7))
                }
            }

            Spacer()

            // Clear all button
            if !drafts.isEmpty {
                Button(action: {
                    showingClearConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SlackTheme.inverseText)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Color.clear
                    .frame(width: 20)
            }
        }
        .padding(.horizontal, SlackTheme.paddingSmall)
    }

    private var draftsList: some View {
        ScrollView {
            VStack(spacing: SlackTheme.paddingSmall) {
                // Info banner
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                    Text("Swipe left to delete • Tap to copy")
                        .font(.system(size: 10))
                }
                .foregroundColor(SlackTheme.tertiaryText)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(SlackTheme.accentPrimary.opacity(0.1))
                .cornerRadius(SlackTheme.cornerRadiusSmall)

                ForEach(Array(drafts.enumerated()), id: \.offset) { index, draft in
                    DraftCard(draft: draft, index: index, onDelete: {
                        deleteDraft(at: index)
                    }, onCopy: {
                        copyToClipboard(draft.content)
                    })
                }
            }
            .padding(SlackTheme.paddingSmall)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: SlackTheme.accentPrimary))
            Text("Loading drafts...")
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
                loadDrafts()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundColor(SlackTheme.tertiaryText)
            Text("No drafts available")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(SlackTheme.primaryText)
            Text("Agents will create drafts when they detect messages needing responses.")
                .font(.system(size: 11))
                .foregroundColor(SlackTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadDrafts() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loaded = try await viewModel.alfredService.fetchDrafts()
                await MainActor.run {
                    self.drafts = loaded
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load drafts: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    private func deleteDraft(at index: Int) {
        Task {
            do {
                try await viewModel.alfredService.deleteDraft(at: index)
                await MainActor.run {
                    if index < drafts.count {
                        drafts.remove(at: index)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to delete draft"
                }
            }
        }
    }

    private func clearAllDrafts() {
        Task {
            do {
                try await viewModel.alfredService.clearDrafts()
                await MainActor.run {
                    self.drafts = []
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to clear drafts"
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Show brief confirmation (could add toast notification)
    }
}

// MARK: - Draft Card Component
struct DraftCard: View {
    let draft: MessageDraft
    let index: Int
    let onDelete: () -> Void
    let onCopy: () -> Void

    @State private var showingFullMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: platformIcon)
                    .font(.system(size: 14))
                    .foregroundColor(SlackTheme.accentPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("To: \(draft.recipient)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SlackTheme.primaryText)

                    Text("\(draft.platform.rawValue.uppercased()) • \(draft.tone.rawValue)")
                        .font(.system(size: 10))
                        .foregroundColor(SlackTheme.secondaryText)
                }

                Spacer()

                Menu {
                    Button(action: onCopy) {
                        Label("Copy Message", systemImage: "doc.on.doc")
                    }
                    Button(action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundColor(SlackTheme.tertiaryText)
                }
                .menuStyle(BorderlessButtonMenuStyle())
            }

            // Message preview
            VStack(alignment: .leading, spacing: 4) {
                Text(messagePreview)
                    .font(.system(size: 11))
                    .foregroundColor(SlackTheme.primaryText)
                    .lineLimit(showingFullMessage ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)

                if draft.content.count > 150 {
                    Button(action: {
                        showingFullMessage.toggle()
                    }) {
                        Text(showingFullMessage ? "Show less" : "Show more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(SlackTheme.accentPrimary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(8)
            .background(SlackTheme.surfaceBackground)
            .cornerRadius(4)

            // Actions
            HStack(spacing: 12) {
                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(SlackTheme.accentPrimary)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Text("Manual sending required")
                    .font(.system(size: 9))
                    .foregroundColor(SlackTheme.tertiaryText)
            }
        }
        .padding(SlackTheme.paddingSmall)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }

    private var platformIcon: String {
        switch draft.platform {
        case .whatsapp:
            return "message.fill"
        case .imessage:
            return "message.badge.filled.fill"
        case .signal:
            return "message.circle.fill"
        case .email:
            return "envelope.fill"
        }
    }

    private var messagePreview: String {
        if showingFullMessage {
            return draft.content
        }
        return String(draft.content.prefix(150))
    }
}
