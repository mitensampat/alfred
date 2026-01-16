import SwiftUI

struct MessageDetailView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    let contact: String
    @State private var showFullConversation = false
    @State private var isLoading = false
    @State private var threadAnalysis: FocusedThreadAnalysis?
    @State private var errorMessage: String?
    @State private var recommendedActions: [RecommendedAction] = []
    @State private var showRecommendations = false
    @State private var isAddingToNotion = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    viewModel.navigateBack()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SlackTheme.primaryText)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Text(contact)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SlackTheme.primaryText)
                    .lineLimit(1)

                Spacer()

                Button(action: {}) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundColor(SlackTheme.primaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, SlackTheme.paddingMedium)
            .padding(.top, SlackTheme.paddingLarge)
            .padding(.bottom, SlackTheme.paddingMedium)

            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(SlackTheme.accentPrimary)
                    Text("Analyzing conversation...")
                        .font(.system(size: 12))
                        .foregroundColor(SlackTheme.secondaryText)
                        .padding(.top, SlackTheme.paddingSmall)
                    Spacer()
                }
            } else if let error = errorMessage {
                VStack {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(SlackTheme.accentDanger)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(SlackTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, SlackTheme.paddingSmall)
                        .padding(.horizontal, SlackTheme.paddingLarge)
                    Spacer()
                }
            } else if let analysis = threadAnalysis {
                ScrollView {
                    VStack(alignment: .leading, spacing: SlackTheme.paddingLarge) {
                        // Context section
                        if !analysis.context.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
                                Text("CONTEXT")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.secondaryText)
                                    .tracking(1)

                                Text(analysis.context)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(SlackTheme.primaryText)
                                    .lineSpacing(4)
                                    .padding(SlackTheme.paddingSmall)
                                    .background(Color.white)
                                    .cornerRadius(SlackTheme.cornerRadiusSmall)
                                    .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
                            }
                        }

                        // Summary section
                        if !analysis.summary.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
                                Text("SUMMARY")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.secondaryText)
                                    .tracking(1)

                                Text(analysis.summary)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(SlackTheme.primaryText)
                                    .lineSpacing(4)
                                    .padding(SlackTheme.paddingSmall)
                                    .background(Color.white)
                                    .cornerRadius(SlackTheme.cornerRadiusSmall)
                                    .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
                            }
                        }

                        // Action items section
                        if !analysis.actionItems.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                                Text("ACTION ITEMS")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.secondaryText)
                                    .tracking(1)

                                ForEach(Array(analysis.actionItems.enumerated()), id: \.offset) { _, item in
                                    ActionItemCard(
                                        priority: item.priority,
                                        title: item.item,
                                        deadline: item.deadline
                                    )
                                }
                            }
                        }

                        // Recommended Actions for Notion
                        if !recommendedActions.isEmpty && showRecommendations {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                                Text("💡 RECOMMENDED FOR NOTION")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.accentPrimary)
                                    .tracking(1)

                                Text("Found \(recommendedActions.count) critical action item(s). Add to your Notion todo list?")
                                    .font(.system(size: 12))
                                    .foregroundColor(SlackTheme.secondaryText)
                                    .lineSpacing(3)

                                ForEach(recommendedActions) { action in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(action.priority.emoji)
                                            .font(.system(size: 14))

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(action.title)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(SlackTheme.primaryText)

                                            if let dueDate = action.dueDate {
                                                Text("Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(SlackTheme.secondaryText)
                                            }
                                        }
                                    }
                                    .padding(SlackTheme.paddingSmall)
                                    .background(Color.white)
                                    .cornerRadius(SlackTheme.cornerRadiusSmall)
                                    .shadow(color: SlackTheme.shadowColor, radius: 1, x: 0, y: 1)
                                }

                                if isAddingToNotion {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Adding to Notion...")
                                            .font(.system(size: 11))
                                            .foregroundColor(SlackTheme.secondaryText)
                                    }
                                    .padding(.vertical, 8)
                                } else {
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            addToNotion()
                                        }) {
                                            Text("Yes, Add All")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(SlackTheme.accentPrimary)
                                                .cornerRadius(SlackTheme.cornerRadiusSmall)
                                        }
                                        .buttonStyle(PlainButtonStyle())

                                        Button(action: {
                                            withAnimation {
                                                showRecommendations = false
                                            }
                                        }) {
                                            Text("No Thanks")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(SlackTheme.primaryText)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(Color.white)
                                                .cornerRadius(SlackTheme.cornerRadiusSmall)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusSmall)
                                                        .stroke(SlackTheme.shadowColor, lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            .padding(SlackTheme.paddingSmall)
                            .background(SlackTheme.accentPrimary.opacity(0.05))
                            .cornerRadius(SlackTheme.cornerRadiusMedium)
                        }

                        // Key messages (collapsible)
                        if !analysis.thread.messages.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                                Button(action: {
                                    withAnimation {
                                        showFullConversation.toggle()
                                    }
                                }) {
                                    HStack {
                                        Text("KEY MESSAGES")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(SlackTheme.secondaryText)
                                            .tracking(1)

                                        Spacer()

                                        Image(systemName: showFullConversation ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(SlackTheme.tertiaryText)
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())

                                if showFullConversation {
                                    VStack(spacing: SlackTheme.paddingSmall) {
                                        ForEach(analysis.thread.messages.prefix(10), id: \.id) { message in
                                            QuoteCard(
                                                timestamp: formatTimestamp(message.timestamp),
                                                speaker: message.sender,
                                                quote: message.content
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(SlackTheme.paddingMedium)
                }
            }
        }
        .onAppear {
            Task {
                await loadThreadAnalysis()
            }
        }
    }

    private func loadThreadAnalysis() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let analysis = try await viewModel.alfredService.fetchFocusedThread(contactName: contact, timeframe: viewModel.selectedMessageTimeframe)
            await MainActor.run {
                self.threadAnalysis = analysis

                // Extract recommended actions
                let actions = viewModel.alfredService.extractRecommendedActions(from: analysis)
                if !actions.isEmpty {
                    self.recommendedActions = actions
                    self.showRecommendations = true
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load thread: \(error.localizedDescription)"
            }
        }
    }

    private func addToNotion() {
        Task {
            await MainActor.run {
                isAddingToNotion = true
            }

            do {
                _ = try await viewModel.alfredService.addRecommendedActionsToNotion(recommendedActions)
                await MainActor.run {
                    isAddingToNotion = false
                    showRecommendations = false
                }
            } catch {
                await MainActor.run {
                    isAddingToNotion = false
                    errorMessage = "Failed to add to Notion: \(error.localizedDescription)"
                }
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ActionItemCard: View {
    let priority: String
    let title: String
    let deadline: String?

    var priorityColor: Color {
        switch priority {
        case "HIGH": return SlackTheme.accentDanger
        case "MEDIUM": return SlackTheme.accentWarning
        default: return SlackTheme.accentPrimary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SlackTheme.primaryText)
            }

            if let deadline = deadline {
                Text("DEADLINE: \(deadline.uppercased())")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(SlackTheme.secondaryText)
                    .tracking(0.5)
            }
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .overlay(
            RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusSmall)
                .stroke(
                    LinearGradient(
                        colors: [priorityColor.opacity(0.3), priorityColor.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

struct QuoteCard: View {
    let timestamp: String
    let speaker: String
    let quote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("[\(timestamp)] \(speaker.uppercased())")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(SlackTheme.secondaryText)
                .tracking(0.5)

            Text("\"\(quote)\"")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(SlackTheme.primaryText)
                .lineSpacing(3)
        }
        .padding(SlackTheme.paddingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 1, x: 0, y: 1)
    }
}
