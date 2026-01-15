import SwiftUI

struct BriefingDetailView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var isLoading = false
    @State private var briefing: DailyBriefing?
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
                    Text("BRIEFING")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(SlackTheme.primaryText)
                        .tracking(1)
                    Text(formatBriefingDate(viewModel.selectedBriefingDate))
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
                    Text("Generating briefing...")
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
            } else if let briefing = briefing {
                ScrollView {
                    VStack(alignment: .leading, spacing: SlackTheme.paddingLarge) {
                        // Summary stats
                        HStack(spacing: SlackTheme.paddingMedium) {
                            StatCard(
                                title: "MEETINGS",
                                value: "\(briefing.calendarBriefing.schedule.events.count)",
                                icon: "calendar"
                            )
                            StatCard(
                                title: "MESSAGES",
                                value: "\(briefing.messagingSummary.stats.totalMessages)",
                                icon: "message"
                            )
                            let focusHours = Int(briefing.calendarBriefing.focusTime) / 3600
                            StatCard(
                                title: "FOCUS TIME",
                                value: "\(focusHours)h",
                                icon: "clock"
                            )
                        }

                        // Top priorities (action items)
                        if !briefing.actionItems.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                                Text("TOP PRIORITIES")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.secondaryText)
                                    .tracking(1)

                                ForEach(Array(briefing.actionItems.prefix(3).enumerated()), id: \.element.id) { index, item in
                                    PriorityCard(
                                        number: index + 1,
                                        title: item.title,
                                        time: formatTime(item.dueDate)
                                    )
                                }
                            }
                        }

                        // Calendar recommendations
                        if !briefing.calendarBriefing.recommendations.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
                                Text("RECOMMENDATIONS")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.secondaryText)
                                    .tracking(1)

                                ForEach(briefing.calendarBriefing.recommendations, id: \.self) { recommendation in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "lightbulb")
                                            .font(.system(size: 11))
                                            .foregroundColor(SlackTheme.accentPrimary)
                                        Text(recommendation)
                                            .font(.system(size: 11))
                                            .foregroundColor(SlackTheme.secondaryText)
                                    }
                                    .padding(SlackTheme.paddingSmall)
                                    .background(Color.white)
                                    .cornerRadius(SlackTheme.cornerRadiusSmall)
                                    .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
                                }
                            }
                        }

                        // Critical messages
                        if !briefing.messagingSummary.criticalMessages.isEmpty {
                            VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
                                Text("CRITICAL MESSAGES")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(SlackTheme.accentDanger)
                                    .tracking(1)

                                ForEach(briefing.messagingSummary.criticalMessages.prefix(3), id: \.thread.contactIdentifier) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.thread.contactName ?? "Unknown")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(SlackTheme.primaryText)
                                        Text(message.summary)
                                            .font(.system(size: 11))
                                            .foregroundColor(SlackTheme.secondaryText)
                                            .lineLimit(2)
                                    }
                                    .padding(SlackTheme.paddingSmall)
                                    .background(SlackTheme.accentDanger.opacity(0.05))
                                    .cornerRadius(SlackTheme.cornerRadiusSmall)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusSmall)
                                            .stroke(SlackTheme.accentDanger.opacity(0.3), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                    .padding(SlackTheme.paddingMedium)
                }
            }

            Spacer()
        }
        .onAppear {
            Task {
                await loadBriefing()
            }
        }
    }

    private func loadBriefing() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let dailyBriefing = try await viewModel.alfredService.generateDailyBriefing(for: viewModel.selectedBriefingDate)
            await MainActor.run {
                self.briefing = dailyBriefing
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to generate briefing: \(error.localizedDescription)"
            }
        }
    }

    private func formatBriefingDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }

    private func formatTime(_ date: Date?) -> String {
        guard let date = date else { return "today" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInTomorrow(date) {
            return "tomorrow"
        } else {
            return "by EOD"
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(SlackTheme.accentPrimary)

            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(SlackTheme.primaryText)

            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(SlackTheme.secondaryText)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SlackTheme.paddingSmall)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }
}

struct PriorityCard: View {
    let number: Int
    let title: String
    let time: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(SlackTheme.accentPrimary)
                .cornerRadius(12)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SlackTheme.primaryText)

                Text(time)
                    .font(.system(size: 10))
                    .foregroundColor(SlackTheme.secondaryText)
            }

            Spacer()
        }
        .padding(SlackTheme.paddingSmall)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }
}
