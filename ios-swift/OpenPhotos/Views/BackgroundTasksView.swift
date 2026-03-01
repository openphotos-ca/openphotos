import SwiftUI

struct BackgroundTasksView: View {
    @State private var tasks: [BgTaskInfo] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text("Loading tasks…") }
                }
                ForEach(tasks, id: \.id) { t in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.desc).font(.subheadline).foregroundColor(.secondary)
                            Text("State: \(t.state)").font(.footnote)
                            if t.responseCode != nil {
                                Text("HTTP: \(t.responseCode!)").font(.footnote)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            let sent = ByteCountFormatter.string(fromByteCount: t.sent, countStyle: .file)
                            let exp = t.expected > 0 ? ByteCountFormatter.string(fromByteCount: t.expected, countStyle: .file) : "—"
                            Text(sent + " / " + exp).font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Background Tasks")
            .toolbar { Button("Refresh", action: refresh) }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        loading = true
        HybridUploadManager.shared.getBackgroundTasks { list in
            DispatchQueue.main.async {
                self.tasks = list
                self.loading = false
            }
        }
    }
}
