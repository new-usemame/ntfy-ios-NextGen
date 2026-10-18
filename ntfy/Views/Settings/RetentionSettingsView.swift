import SwiftUI

struct RetentionSettingsView: View {
    @EnvironmentObject private var store: Store
    @State private var showSaveError = false
    @State private var policy: NotificationRetention = .forever

    var body: some View {
        Section(header: Text(NotificationHistoryStrings.section), footer: Text(NotificationHistoryStrings.explanation)) {
            Picker(NotificationHistoryStrings.title, selection: $policy) {
                ForEach(NotificationRetention.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .onAppear { policy = store.notificationRetention() }
            .onChange(of: policy) { value in
                guard value != store.notificationRetention() else { return }
                if !store.saveNotificationRetention(value) {
                    policy = store.notificationRetention()
                    showSaveError = true
                }
            }
        }
        .alert(isPresented: $showSaveError) {
            Alert(title: Text(NotificationHistoryStrings.saveError), message: Text(NotificationHistoryStrings.saveErrorExplanation))
        }
    }
}
