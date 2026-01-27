import SwiftUI

struct MainMenuView: View {
    @StateObject private var viewModel = MainMenuViewModel()
    @State private var searchText = ""

    var body: some View {
        ZStack {
            SlackTheme.surfaceBackground
                .ignoresSafeArea()

            Group {
                switch viewModel.currentView {
                case .main:
                    mainMenuContent
                case .briefingOptions:
                    BriefingOptionsView(viewModel: viewModel)
                case .briefing:
                    BriefingDetailView(viewModel: viewModel)
                case .calendarOptions:
                    CalendarOptionsView(viewModel: viewModel)
                case .calendar:
                    CalendarDetailView(viewModel: viewModel)
                case .messagesOptions:
                    MessagesOptionsView(viewModel: viewModel)
                case .messages:
                    MessagesListView(viewModel: viewModel)
                case .messageDetail:
                    MessageDetailView(viewModel: viewModel, contact: viewModel.selectedMessageContact)
                case .attentionCheck:
                    AttentionCheckView(viewModel: viewModel)
                case .notionTodos:
                    NotionTodosView(viewModel: viewModel)
                case .commitments:
                    CommitmentsView(viewModel: viewModel)
                case .drafts:
                    DraftsView(viewModel: viewModel)
                }
            }
        }
        .frame(
            width: viewModel.shouldExpandPopover ? 680 : 340,
            height: viewModel.shouldExpandPopover ? 760 : 380
        )
        .animation(.easeInOut(duration: 0.2), value: viewModel.shouldExpandPopover)
        .onAppear {
            viewModel.loadData()
        }
    }

    private var mainMenuContent: some View {
        VStack(spacing: 0) {
                // Header with aubergine background
                headerView
                    .padding(.top, SlackTheme.paddingMedium)
                    .padding(.bottom, SlackTheme.paddingSmall)
                    .frame(maxWidth: .infinity)
                    .background(SlackTheme.primaryBackground)

                // Main menu items
                ScrollView {
                    VStack(spacing: SlackTheme.paddingSmall) {
                        MainMenuItem(icon: "calendar", title: "briefing", subtitle: "daily summary & insights")
                            .onTapGesture { viewModel.showBriefingOptions() }

                        MainMenuItem(icon: "calendar.badge.clock", title: "calendar", subtitle: "meetings & schedule")
                            .onTapGesture { viewModel.showCalendarOptions() }

                        MainMenuItem(icon: "message", title: "messages", subtitle: "recent conversations")
                            .onTapGesture { viewModel.showMessagesOptions() }

                        MainMenuItem(icon: "list.bullet.clipboard", title: "commitments", subtitle: "track promises & obligations")
                            .onTapGesture { viewModel.showCommitments() }

                        MainMenuItem(icon: "doc.text", title: "agent drafts", subtitle: "review AI-generated messages")
                            .onTapGesture { viewModel.showDrafts() }

                        MainMenuItem(icon: "checkmark.circle", title: "scan for todos", subtitle: "check whatsapp notes")
                            .onTapGesture { viewModel.navigate(to: .notionTodos) }

                        MainMenuItem(icon: "eye", title: "attention check", subtitle: "what can you push off?")
                            .onTapGesture { viewModel.navigate(to: .attentionCheck) }
                    }
                    .padding(.horizontal, SlackTheme.paddingSmall)
                    .padding(.top, SlackTheme.paddingSmall)
                }

                Spacer()

                // Footer branding
                footerView
            }
    }

    private var footerView: some View {
        Text("crafted by ms foundry")
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(SlackTheme.tertiaryText)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(SlackTheme.surfaceBackground)
    }

    private var headerView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("alfred")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundColor(SlackTheme.inverseText)

                Text("v1.4.2")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(SlackTheme.inverseText.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(SlackTheme.inverseText.opacity(0.15))
                    .cornerRadius(4)
            }

            Text("judgement from noise")
                .font(.system(size: 10, weight: .regular, design: .serif))
                .foregroundColor(SlackTheme.inverseText.opacity(0.7))
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(SlackTheme.tertiaryText)
                .font(.system(size: 12))

            TextField("search...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.primaryText)
        }
        .padding(.horizontal, SlackTheme.paddingSmall)
        .padding(.vertical, 8)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 1, x: 0, y: 1)
    }

    private var moreOptionsButton: some View {
        Button(action: {
            viewModel.showMoreOptions()
        }) {
            HStack(spacing: 3) {
                Circle()
                    .fill(SlackTheme.tertiaryText)
                    .frame(width: 3, height: 3)
                Circle()
                    .fill(SlackTheme.tertiaryText)
                    .frame(width: 3, height: 3)
                Circle()
                    .fill(SlackTheme.tertiaryText)
                    .frame(width: 3, height: 3)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct PriorityItemCard: View {
    let item: PriorityItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SlackTheme.primaryText)

                    Text(item.subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(SlackTheme.secondaryText)
                }

                Spacer()

                if let badge = item.badge {
                    badgeView(badge)
                }

                if item.hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SlackTheme.tertiaryText)
                }
            }
        }
        .padding(SlackTheme.paddingSmall)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private func badgeView(_ badge: PriorityItemBadge) -> some View {
        switch badge {
        case .count(let number):
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(SlackTheme.accentPrimary)
                .cornerRadius(6)
        case .alert:
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundColor(SlackTheme.accentDanger)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(SlackTheme.accentSuccess)
        }
    }
}

// MARK: - Main Menu Item Component
struct MainMenuItem: View {
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

// MARK: - Preview
struct MainMenuView_Previews: PreviewProvider {
    static var previews: some View {
        MainMenuView()
    }
}
