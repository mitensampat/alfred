import SwiftUI

struct MessagesOptionsView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var searchText: String = ""
    @State private var timeframe: String = "24h"
    
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
                
                Text("MESSAGES")
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
                VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                    Text("SELECT PLATFORM")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(SlackTheme.secondaryText)
                        .tracking(1)
                    
                    // Platform options
                    OptionCard(icon: "bubble.left.and.bubble.right", title: "all platforms", subtitle: "analyze all messages")
                        .onTapGesture {
                            viewModel.selectedMessagePlatform = "all"
                            viewModel.selectedMessageTimeframe = "24h"
                            viewModel.navigate(to: .messages)
                        }
                    
                    OptionCard(icon: "message", title: "imessage", subtitle: "iMessage conversations only")
                        .onTapGesture {
                            viewModel.selectedMessagePlatform = "imessage"
                            viewModel.selectedMessageTimeframe = "24h"
                            viewModel.navigate(to: .messages)
                        }
                    
                    OptionCard(icon: "phone.bubble", title: "whatsapp", subtitle: "WhatsApp conversations only")
                        .onTapGesture {
                            viewModel.selectedMessagePlatform = "whatsapp"
                            viewModel.selectedMessageTimeframe = "24h"
                            viewModel.navigate(to: .messages)
                        }
                    
                    Text("FOCUSED THREAD SEARCH")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(SlackTheme.secondaryText)
                        .tracking(1)
                        .padding(.top, SlackTheme.paddingMedium)
                    
                    // Focused WhatsApp search
                    VStack(alignment: .leading, spacing: SlackTheme.paddingSmall) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search WhatsApp contact or group")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(SlackTheme.primaryText)
                            
                            TextField("Enter name (e.g., John Doe)", text: $searchText)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 12))
                                .padding(SlackTheme.paddingSmall)
                                .background(SlackTheme.surfaceBackground)
                                .cornerRadius(SlackTheme.cornerRadiusSmall)
                                .overlay(
                                    RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusSmall)
                                        .stroke(SlackTheme.shadowColor, lineWidth: 1)
                                )
                            
                            HStack(spacing: SlackTheme.paddingSmall) {
                                Text("Timeframe:")
                                    .font(.system(size: 11))
                                    .foregroundColor(SlackTheme.secondaryText)

                                ForEach(["30m", "2h", "8h", "24h", "3d", "7d"], id: \.self) { option in
                                    Button(action: {
                                        timeframe = option
                                    }) {
                                        Text(option)
                                            .font(.system(size: 11, weight: timeframe == option ? .semibold : .regular))
                                            .foregroundColor(timeframe == option ? Color.white : SlackTheme.primaryText)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(timeframe == option ? SlackTheme.accentPrimary : Color.clear)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(timeframe == option ? SlackTheme.accentPrimary : SlackTheme.shadowColor, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                            Button(action: {
                                if !searchText.isEmpty {
                                    viewModel.selectedMessageContact = searchText
                                    viewModel.selectedMessageTimeframe = timeframe
                                    viewModel.navigate(to: .messageDetail)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 12))
                                    Text("Search Thread")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(Color.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(searchText.isEmpty ? SlackTheme.tertiaryText : SlackTheme.accentPrimary)
                                .cornerRadius(SlackTheme.cornerRadiusSmall)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(searchText.isEmpty)
                        }
                        .padding(SlackTheme.paddingMedium)
                        .background(Color.white)
                        .cornerRadius(SlackTheme.cornerRadiusMedium)
                        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
                    }
                }
                .padding(SlackTheme.paddingMedium)
            }
            
            Spacer()
        }
    }
}