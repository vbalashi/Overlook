import Foundation

struct QuickPasteSnippet: Identifiable, Codable {
    var id: UUID = UUID()
    var label: String
    var text: String
    var isHidden: Bool = false
}

@MainActor
final class QuickPasteManager: ObservableObject {
    @Published var snippets: [QuickPasteSnippet] = []

    private static let defaultsKey = "overlook.quickPasteSnippets.v1"

    init() {
        load()
    }

    func addSnippet(label: String, text: String, isHidden: Bool) {
        snippets.append(QuickPasteSnippet(label: label, text: text, isHidden: isHidden))
        save()
    }

    func deleteSnippet(_ snippet: QuickPasteSnippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func updateSnippet(_ snippet: QuickPasteSnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    func moveSnippets(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func send(_ snippet: QuickPasteSnippet, via client: GLKVMClient) {
        Task {
            try? await client.hidPrint(text: snippet.text)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([QuickPasteSnippet].self, from: data)
        else { return }
        snippets = decoded
    }
}
