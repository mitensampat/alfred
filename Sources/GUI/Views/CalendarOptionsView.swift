import SwiftUI

struct CalendarOptionsView: View {
    @ObservedObject var viewModel: MainMenuViewModel

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

                Text("CALENDAR")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(SlackTheme.primaryText)
                    .tracking(1)

                Spacer()

                Image(systemName: "chevron.left")
                    .font(.system(size: 16))
                    .opacity(0)
            }
            .padding(.horizontal, SlackTheme.paddingMedium)
            .padding(.top, SlackTheme.paddingLarge)
            .padding(.bottom, SlackTheme.paddingMedium)

            // Calendar options
            ScrollView {
                VStack(spacing: SlackTheme.paddingSmall) {
                    // Date options
                    OptionCard(
                        icon: "sun.max",
                        title: "today",
                        subtitle: "calendar for today"
                    )
                    .onTapGesture {
                        viewModel.selectedCalendarDate = Date()
                        viewModel.navigate(to: .calendar)
                    }

                    OptionCard(
                        icon: "sunrise",
                        title: "tomorrow",
                        subtitle: "calendar for tomorrow"
                    )
                    .onTapGesture {
                        viewModel.selectedCalendarDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                        viewModel.navigate(to: .calendar)
                    }

                    OptionCard(
                        icon: "calendar",
                        title: "specific date",
                        subtitle: "choose a date"
                    )
                    .onTapGesture {
                        // TODO: Show date picker
                        print("Show date picker for calendar")
                    }

                    Divider()
                        .padding(.vertical, SlackTheme.paddingSmall)

                    // Calendar filter options
                    Text("CALENDAR FILTER")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(SlackTheme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SlackTheme.paddingSmall)

                    OptionCard(
                        icon: "calendar.badge.checkmark",
                        title: "all calendars",
                        subtitle: "show all events"
                    )
                    .onTapGesture {
                        viewModel.selectedCalendarFilter = "all"
                        viewModel.navigate(to: .calendar)
                    }

                    OptionCard(
                        icon: "person",
                        title: "primary calendar",
                        subtitle: "personal events only"
                    )
                    .onTapGesture {
                        viewModel.selectedCalendarFilter = "primary"
                        viewModel.navigate(to: .calendar)
                    }

                    OptionCard(
                        icon: "briefcase",
                        title: "work calendar",
                        subtitle: "work events only"
                    )
                    .onTapGesture {
                        viewModel.selectedCalendarFilter = "work"
                        viewModel.navigate(to: .calendar)
                    }
                }
                .padding(.horizontal, SlackTheme.paddingMedium)
            }

            Spacer()
        }
    }
}
