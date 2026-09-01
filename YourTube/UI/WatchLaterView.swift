import SwiftUI
import SwiftData

struct WatchLaterView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Video> { $0.savedForLaterAt != nil },
        sort: [SortDescriptor(\Video.savedForLaterAt, order: .reverse)]
    )
    private var saved: [Video]

    var body: some View {
        NavigationStack {
            Group {
                if saved.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved",
                        systemImage: "clock",
                        description: Text("Videos you save from the player show up here.")
                    )
                } else {
                    List {
                        ForEach(saved) { video in
                            NavigationLink {
                                PlayerView(video: video)
                            } label: {
                                VideoRow(video: video)
                            }
                        }
                        .onDelete(perform: remove)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Watch Later")
        }
    }

    private func remove(at offsets: IndexSet) {
        for index in offsets {
            saved[index].savedForLaterAt = nil
        }
        try? modelContext.save()
    }
}
