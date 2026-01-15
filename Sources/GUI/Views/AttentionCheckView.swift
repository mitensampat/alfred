import SwiftUI

struct AttentionCheckView: View {
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

                Text("ATTENTION CHECK")
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

            ScrollView {
                VStack(alignment: .leading, spacing: SlackTheme.paddingLarge) {
                    // Alert message
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 24))
                            .foregroundColor(SlackTheme.accentDanger)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("3:00 PM Check-in")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(SlackTheme.primaryText)

                            Text("Time to prioritize what matters")
                                .font(.system(size: 12))
                                .foregroundColor(SlackTheme.secondaryText)
                        }
                    }
                    .padding(SlackTheme.paddingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusMedium)
                            .stroke(SlackTheme.accentDanger.opacity(0.3), lineWidth: 1)
                    )

                    // Must do today
                    VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                        Text("MUST COMPLETE TODAY")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(SlackTheme.secondaryText)
                            .tracking(1)

                        CriticalTaskCard(
                            title: "RBI documentation review",
                            reason: "Meeting tomorrow morning",
                            impact: "HIGH"
                        )

                        CriticalTaskCard(
                            title: "Approve Q1 budget",
                            reason: "Finance needs it by EOD",
                            impact: "HIGH"
                        )

                        CriticalTaskCard(
                            title: "Review PR #234",
                            reason: "Blocks deployment",
                            impact: "MEDIUM"
                        )
                    }

                    // Can push off
                    VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                        Text("CAN PUSH TO TOMORROW")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(SlackTheme.secondaryText)
                            .tracking(1)

                        PushOffTaskCard(
                            title: "Update team wiki",
                            reason: "Not time-sensitive, can do tomorrow morning",
                            impact: "LOW"
                        )

                        PushOffTaskCard(
                            title: "Reply to recruiting emails",
                            reason: "No urgent candidates",
                            impact: "LOW"
                        )
                    }
                }
                .padding(SlackTheme.paddingMedium)
            }

            Spacer()
        }
    }
}

struct CriticalTaskCard: View {
    let title: String
    let reason: String
    let impact: String

    var impactColor: Color {
        impact == "HIGH" ? SlackTheme.accentDanger : SlackTheme.accentWarning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(impactColor)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SlackTheme.primaryText)
            }

            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)

            Text("IMPACT: \(impact)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(impactColor)
                .tracking(0.5)
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusMedium)
                .stroke(impactColor.opacity(0.3), lineWidth: 1)
        )
    }
}

struct PushOffTaskCard: View {
    let title: String
    let reason: String
    let impact: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(SlackTheme.primaryText)

            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)
                .lineSpacing(2)
        }
        .padding(SlackTheme.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }
}
