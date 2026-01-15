import SwiftUI

struct CalendarDetailView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var isLoading = false
    @State private var calendarBriefing: CalendarBriefing?
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
                    Text("CALENDAR BRIEFING")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(SlackTheme.primaryText)
                        .tracking(1)
                    Text(formatDateHeader(viewModel.selectedCalendarDate))
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
                    Text("Analyzing your calendar...")
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
            } else if let briefing = calendarBriefing {
                ScrollView {
                    VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                        // Date header
                        Text(formatDate(Date()))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(SlackTheme.secondaryText)
                            .tracking(1)

                        // Overview section
                        SectionCard(
                            title: "Overview",
                            icon: "calendar",
                            content: scheduleSummary(briefing.schedule)
                        )

                        // Meeting briefings (AI-generated insights)
                        if !briefing.meetingBriefings.isEmpty {
                            Text("MEETING BRIEFINGS")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(SlackTheme.secondaryText)
                                .tracking(1)

                            ForEach(briefing.meetingBriefings, id: \.event.id) { meetingBriefing in
                                MeetingBriefingCard(briefing: meetingBriefing)
                            }
                        }

                        // Recommendations
                        if !briefing.recommendations.isEmpty {
                            SectionCard(
                                title: "Recommendations",
                                icon: "lightbulb",
                                content: briefing.recommendations.joined(separator: "\n\n")
                            )
                        }

                        // Focus time
                        if briefing.focusTime > 0 {
                            let hours = Int(briefing.focusTime) / 3600
                            let minutes = (Int(briefing.focusTime) % 3600) / 60
                            let focusText = hours > 0 ? "\(hours)h \(minutes)m of focus time available" : "\(minutes)m of focus time available"

                            SectionCard(
                                title: "Focus Time",
                                icon: "brain.head.profile",
                                content: focusText
                            )
                        }
                    }
                    .padding(SlackTheme.paddingMedium)
                }
            }

            Spacer()
        }
        .onAppear {
            Task {
                await loadCalendarBriefing()
            }
        }
    }

    private func loadCalendarBriefing() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let briefing = try await viewModel.alfredService.fetchCalendarBriefing(
                for: viewModel.selectedCalendarDate,
                calendar: viewModel.selectedCalendarFilter
            )
            await MainActor.run {
                self.calendarBriefing = briefing
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load calendar: \(error.localizedDescription)"
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date).uppercased()
    }

    private func formatDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today • \(viewModel.selectedCalendarFilter)"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow • \(viewModel.selectedCalendarFilter)"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "\(formatter.string(from: date)) • \(viewModel.selectedCalendarFilter)"
        }
    }

    private func scheduleSummary(_ schedule: DailySchedule) -> String {
        let totalHours = Int(schedule.totalMeetingTime) / 3600
        let totalMinutes = (Int(schedule.totalMeetingTime) % 3600) / 60
        let eventCount = schedule.events.count
        let externalCount = schedule.externalMeetings.count

        var summary = "\(eventCount) meeting\(eventCount != 1 ? "s" : "") scheduled"
        if totalHours > 0 {
            summary += " (\(totalHours)h \(totalMinutes)m total)"
        } else {
            summary += " (\(totalMinutes)m total)"
        }

        if externalCount > 0 {
            summary += "\n\(externalCount) external meeting\(externalCount != 1 ? "s" : "") with AI-generated briefings"
        }

        return summary
    }
}

struct SectionCard: View {
    let title: String
    let icon: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(SlackTheme.accentPrimary)

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(SlackTheme.primaryText)
            }

            Text(content)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusMedium)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }
}

struct MeetingBriefingCard: View {
    let briefing: MeetingBriefing

    var body: some View {
        VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
            // Meeting title and time
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(briefing.event.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(SlackTheme.primaryText)

                    Text(formatTime(briefing.event.startTime))
                        .font(.system(size: 11))
                        .foregroundColor(SlackTheme.tertiaryText)
                }

                Spacer()

                Image(systemName: "person.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(SlackTheme.accentPrimary)
            }

            Divider()

            // Context
            if let context = briefing.context, !context.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SlackTheme.secondaryText)
                    Text(context)
                        .font(.system(size: 11))
                        .foregroundColor(SlackTheme.secondaryText)
                }
            }

            // Preparation
            if !briefing.preparation.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preparation")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SlackTheme.secondaryText)
                    Text(briefing.preparation)
                        .font(.system(size: 11))
                        .foregroundColor(SlackTheme.secondaryText)
                }
            }

            // Key attendees
            if !briefing.attendeeBriefings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Attendees")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SlackTheme.secondaryText)

                    ForEach(briefing.attendeeBriefings, id: \.attendee.email) { attendeeBriefing in
                        Text("• \(attendeeBriefing.attendee.name ?? attendeeBriefing.attendee.email)")
                            .font(.system(size: 11))
                            .foregroundColor(SlackTheme.secondaryText)
                    }
                }
            }
        }
        .padding(SlackTheme.paddingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SlackTheme.accentPrimary.opacity(0.05))
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .overlay(
            RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusSmall)
                .stroke(SlackTheme.accentPrimary.opacity(0.3), lineWidth: 1.5)
        )
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
