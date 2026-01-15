import SwiftUI

struct BriefingOptionsView: View {
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

                Text("BRIEFING")
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

            // Briefing options
            ScrollView {
                VStack(spacing: SlackTheme.paddingSmall) {
                    OptionCard(
                        icon: "sun.max",
                        title: "today",
                        subtitle: "briefing for today"
                    )
                    .onTapGesture {
                        viewModel.selectedBriefingDate = Date()
                        viewModel.navigate(to: .briefing)
                    }

                    OptionCard(
                        icon: "sunrise",
                        title: "tomorrow",
                        subtitle: "briefing for tomorrow"
                    )
                    .onTapGesture {
                        viewModel.selectedBriefingDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                        viewModel.navigate(to: .briefing)
                    }

                    OptionCard(
                        icon: "calendar",
                        title: "specific date",
                        subtitle: "choose a date"
                    )
                    .onTapGesture {
                        // TODO: Show date picker
                        print("Show date picker for briefing")
                    }

                    OptionCard(
                        icon: "arrow.clockwise",
                        title: "refresh briefing",
                        subtitle: "regenerate with latest data"
                    )
                    .onTapGesture {
                        // TODO: Regenerate briefing
                        print("Regenerate briefing")
                    }
                }
                .padding(.horizontal, SlackTheme.paddingMedium)
            }

            Spacer()
        }
    }
}

struct OptionCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(SlackTheme.accentPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SlackTheme.primaryText)

                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(SlackTheme.secondaryText)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SlackTheme.tertiaryText)
        }
        .padding(SlackTheme.paddingSmall)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }
}
