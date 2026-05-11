import SwiftUI

// MARK: - Popover

struct QuickPasteView: View {
    @EnvironmentObject var quickPasteManager: QuickPasteManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    @State private var showingAdd = false
    @State private var showingManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Quick Paste")
                    .font(.headline)
                Spacer()
                Button(action: { showingManage = true }) {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.plain)
                .help("Manage snippets")

                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New snippet")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if quickPasteManager.snippets.isEmpty {
                Text("No saved snippets.\nPress + to add one.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 12)
            } else {
                ForEach(quickPasteManager.snippets) { snippet in
                    SnippetRow(snippet: snippet)
                    Divider()
                }
            }
        }
        .frame(width: 280)
        .sheet(isPresented: $showingAdd) {
            SnippetFormView(isPresented: $showingAdd, existing: nil)
        }
        .sheet(isPresented: $showingManage) {
            ManageSnippetsView(isPresented: $showingManage)
        }
    }
}

// MARK: - Popover row

private struct SnippetRow: View {
    @EnvironmentObject var quickPasteManager: QuickPasteManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    let snippet: QuickPasteSnippet
    @State private var justSent = false

    private var previewText: String {
        if snippet.isHidden {
            return String(repeating: "•", count: min(snippet.text.count, 16))
        }
        return snippet.text.count > 30 ? String(snippet.text.prefix(30)) + "…" : snippet.text
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.label)
                    .font(.body)
                    .lineLimit(1)
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(justSent ? "Sent!" : "Send") {
                guard let client = kvmDeviceManager.glkvmClient else { return }
                quickPasteManager.send(snippet, via: client)
                justSent = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    justSent = false
                }
            }
            .disabled(kvmDeviceManager.glkvmClient == nil)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            Button(role: .destructive) {
                quickPasteManager.deleteSnippet(snippet)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Manage sheet

struct ManageSnippetsView: View {
    @EnvironmentObject var quickPasteManager: QuickPasteManager
    @Binding var isPresented: Bool

    @State private var editingSnippet: QuickPasteSnippet? = nil
    @State private var showingAdd = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Snippets")
                    .font(.headline)
                Spacer()
                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New snippet")
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .padding(.leading, 4)
            }
            .padding()

            Divider()

            if quickPasteManager.snippets.isEmpty {
                Text("No snippets yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(quickPasteManager.snippets) { snippet in
                        ManageRow(snippet: snippet, onEdit: { editingSnippet = snippet })
                    }
                    .onMove { quickPasteManager.moveSnippets(from: $0, to: $1) }
                    .onDelete { indexSet in
                        for i in indexSet { quickPasteManager.deleteSnippet(quickPasteManager.snippets[i]) }
                    }
                }
                .listStyle(.inset)

                Text("Drag to reorder · Swipe to delete")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 280, height: 360)
        .sheet(item: $editingSnippet) { snippet in
            SnippetFormView(isPresented: Binding(
                get: { editingSnippet != nil },
                set: { if !$0 { editingSnippet = nil } }
            ), existing: snippet)
        }
        .sheet(isPresented: $showingAdd) {
            SnippetFormView(isPresented: $showingAdd, existing: nil)
        }
    }
}

private struct ManageRow: View {
    @EnvironmentObject var quickPasteManager: QuickPasteManager

    let snippet: QuickPasteSnippet
    let onEdit: () -> Void

    private var previewText: String {
        if snippet.isHidden {
            return String(repeating: "•", count: min(snippet.text.count, 16))
        }
        return snippet.text.count > 40 ? String(snippet.text.prefix(40)) + "…" : snippet.text
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.label)
                    .font(.body)
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { onEdit() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Add / Edit form

struct SnippetFormView: View {
    @EnvironmentObject var quickPasteManager: QuickPasteManager
    @Binding var isPresented: Bool

    /// nil = add mode, non-nil = edit mode
    let existing: QuickPasteSnippet?

    @State private var label: String = ""
    @State private var text: String = ""
    @State private var isHidden: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Snippet" : "Edit Snippet")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Label")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. Server Login Password", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Text to send")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Hide", isOn: $isHidden)
                        .toggleStyle(.checkbox)
                        .font(.subheadline)
                }

                if isHidden {
                    SecureField("Enter text…", text: $text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                }
            }

            HStack {
                if let existing {
                    Button(role: .destructive) {
                        quickPasteManager.deleteSnippet(existing)
                        isPresented = false
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                Button("Cancel") { isPresented = false }
                Spacer()
                Button(existing == nil ? "Save" : "Update") {
                    if var updated = existing {
                        updated.label = label
                        updated.text = text
                        updated.isHidden = isHidden
                        quickPasteManager.updateSnippet(updated)
                    } else {
                        quickPasteManager.addSnippet(label: label, text: text, isHidden: isHidden)
                    }
                    isPresented = false
                }
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            if let s = existing {
                label = s.label
                text = s.text
                isHidden = s.isHidden
            }
        }
    }
}
