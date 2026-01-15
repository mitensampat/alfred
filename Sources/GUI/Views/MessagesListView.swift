import SwiftUI

struct MessagesListView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var isLoading = false
    @State private var errorMessage: String?

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

                VStack(spacing: 2) {
                    Text("MESSAGES")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(SlackTheme.primaryText)
                        .tracking(1)

                    Text("\(viewModel.selectedMessagePlatform) • \(viewModel.selectedMessageTimeframe)")
                        .font(.system(size: 10))
                        .foregroundColor(SlackTheme.secondaryText)
                }

                Spacer()

                Image(systemName: "chevron.left")
                    .font(.system(size: 16))
                    .opacity(0)
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
                    Text("Analyzing messages...")
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
            } else if !viewModel.messageSummaries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                        Text("LAST 24 HOURS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(SlackTheme.secondaryText)
                            .tracking(1)

                        ForEach(viewModel.messageSummaries, id: \.thread.contactIdentifier) { summary in
                            MessageSummaryCard(summary: summary)
                                .onTapGesture {
                                    if let contact = summary.thread.contactName {
                                        viewModel.openMessageDetail(contact: contact)
                                    }
                                }
                        }
                    }
                    .padding(SlackTheme.paddingMedium)
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(SlackTheme.tertiaryText)
                    Text("No messages found")
                        .font(.system(size: 12))
                        .foregroundColor(SlackTheme.secondaryText)
                        .padding(.top, SlackTheme.paddingSmall)
                    Spacer()
                }
            }

            Spacer()
        }
        .onAppear {
            Task {
                await loadMessages()
            }
        }
    }

    private func loadMessages() async {
        guard !isLoading && viewModel.messageSummaries.isEmpty else { return }
        NSLog("📱 Starting to load messages...")
        isLoading = true
        defer { isLoading = false }

        do {
            NSLog("📱 Fetching message summaries from service - platform: \(viewModel.selectedMessagePlatform), timeframe: \(viewModel.selectedMessageTimeframe)")
            let summaries = try await viewModel.alfredService.fetchMessagesSummary(platform: viewModel.selectedMessagePlatform, timeframe: viewModel.selectedMessageTimeframe)
            NSLog("📱 Successfully fetched \(summaries.count) message summaries")
            await MainActor.run {
                viewModel.messageSummaries = summaries
                viewModel.unreadCount = summaries.filter { $0.thread.needsResponse }.count
            }
        } catch {
            NSLog("❌ Error loading messages: \(error)")
            NSLog("❌ Error localized description: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = "Failed to load messages: \(error.localizedDescription)"
            }
        }
    }
}

struct MessageSummaryCard: View {
    let summary: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
            // Header with contact and urgency
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.thread.contactName ?? "Unknown")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(SlackTheme.primaryText)

                    HStack(spacing: 4) {
                        Text("\(summary.thread.platform)")
                            .font(.system(size: 10))
                            .foregroundColor(SlackTheme.tertiaryText)

                        Text("•")
                            .font(.system(size: 10))
                            .foregroundColor(SlackTheme.tertiaryText)

                        Text("\(summary.thread.messages.count) messages")
                            .font(.system(size: 10))
                            .foregroundColor(SlackTheme.tertiaryText)
                    }
                }

                Spacer()

                // Urgency badge
                urgencyBadge(summary.urgency)
            }

            Divider()

            // AI-generated summary
            Text(summary.summary)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Action items if any
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action Items:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SlackTheme.primaryText)

                    ForEach(Array(summary.actionItems.prefix(3).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundColor(SlackTheme.accentPrimary)
                            Text(item)
                                .font(.system(size: 11))
                                .foregroundColor(SlackTheme.secondaryText)
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Needs response indicator
            if summary.thread.needsResponse {
                HStack {
                    Image(systemName: "arrow.turn.up.left")
                        .font(.system(size: 10))
                        .foregroundColor(SlackTheme.accentDanger)
                    Text("Needs response")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SlackTheme.accentDanger)
                }
                .padding(.top, 4)
            }
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor(summary.urgency))
        .cornerRadius(SlackTheme.cornerRadiusMedium)
        .overlay(
            RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusMedium)
                .stroke(borderColor(summary.urgency), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func urgencyBadge(_ urgency: UrgencyLevel) -> some View {
        let (text, color): (String, Color) = {
            switch urgency {
            case .critical:
                return ("CRITICAL", SlackTheme.accentDanger)
            case .high:
                return ("HIGH", SlackTheme.accentWarning)
            case .medium:
                return ("MEDIUM", SlackTheme.accentPrimary)
            case .low:
                return ("LOW", SlackTheme.tertiaryText)
            }
        }()

        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }

    private func backgroundColor(_ urgency: UrgencyLevel) -> Color {
        switch urgency {
        case .critical, .high:
            return SlackTheme.accentDanger.opacity(0.05)
        default:
            return Color.white
        }
    }

    private func borderColor(_ urgency: UrgencyLevel) -> Color {
        switch urgency {
        case .critical:
            return SlackTheme.accentDanger.opacity(0.3)
        case .high:
            return SlackTheme.accentWarning.opacity(0.3)
        default:
            return SlackTheme.shadowColor
        }
    }
}
