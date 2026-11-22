import SwiftUI

/// One exchange: what you said and what Jax said back.
struct Turn: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var you: String
    var jax = ""
}

/// The conversations you had in this app, kept on this phone.
/// ponytail: one JSON file, newest 500 turns. Move to Jax's own memory on the
/// PC when history needs to follow you across devices.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var turns: [Turn] = []
    private let file: URL
    private var saveWork: DispatchWorkItem?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Turn].self, from: data) {
            turns = saved
        }
    }

    func add(you: String) -> UUID {
        let turn = Turn(you: you)
        turns.append(turn)
        if turns.count > 500 { turns.removeFirst(turns.count - 500) }
        save()
        return turn.id
    }

    func setReply(_ text: String, for id: UUID) {
        guard let i = turns.lastIndex(where: { $0.id == id }) else { return }
        turns[i].jax = text
        save()
    }

    func clear() {
        turns = []
        save()
    }

    /// Replies arrive a sentence at a time. Write once things settle, not on every sentence.
    private func save() {
        saveWork?.cancel()
        let snapshot = turns
        let target = file
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// Jax's own iMessage number, from JAX_TEXT_NUMBER in Config/*.xcconfig.
/// Empty means no text line, and the menu item is hidden.
private let jaxTextLine: URL? = {
    let n = (Bundle.main.object(forInfoDictionaryKey: "JaxTextNumber") as? String ?? "").trimmingCharacters(in: .whitespaces)
    return n.isEmpty ? nil : URL(string: "sms:\(n)")
}()

/// Everything you and Jax said, spoken or typed, oldest first, with a box to type in.
/// While this is open Jax answers in text only.
struct MessagesView: View {
    @ObservedObject var jax: JaxClient
    @ObservedObject var store: HistoryStore
    @State private var draft = ""
    @State private var confirmClear = false
    @FocusState private var typing: Bool
    @Environment(\.openURL) private var openURL

    private var days: [(day: Date, turns: [Turn])] {
        let grouped = Dictionary(grouping: store.turns) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.date < $1.date }) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.turns.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32)).foregroundStyle(Look.sky)
                            Text("No messages yet").font(.system(size: 20, weight: .semibold))
                            Text("Type below, or talk on the main screen. Both show up here.")
                                .font(.system(size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 96)
                    }
                    ForEach(days, id: \.day) { day in
                        Text(day.day.formatted(.dateTime.weekday(.wide).month().day()))
                            .font(.system(size: 16, weight: .semibold)).tracking(1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                        ForEach(day.turns) { turn in
                            bubble(turn.you, mine: true)
                            if !turn.jax.isEmpty {
                                bubble(turn.jax, mine: false)
                            } else if turn.id == store.turns.last?.id, jax.phase == .thinking || jax.phase == .searching {
                                bubble(jax.phase == .searching ? "Searching…" : "Thinking…", mine: false).opacity(0.6)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: store.turns.last?.jax) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: store.turns.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .onAppear { jax.setQuiet(true) }
        .onDisappear { jax.setQuiet(false) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    if let line = jaxTextLine {
                        Button { openURL(line) } label: { Label("Text Jax in iMessage", systemImage: "message") }
                    }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear this list", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog("Delete these messages from this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete messages", role: .destructive) { store.clear() }
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 16)).lineSpacing(4)
            .foregroundStyle(mine ? Color.black : Color.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(mine ? AnyShapeStyle(Look.sky) : AnyShapeStyle(Look.panel), in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: 320, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .accessibilityLabel(mine ? "You: \(text)" : "Jax: \(text)")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !jax.hint.isEmpty {
                Text(jax.hint).font(.system(size: 16)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Jax", text: $draft, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($typing)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Look.panel, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(Look.sky, in: Circle())
                }
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Look.background)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendDraft() {
        let text = trimmed
        guard !text.isEmpty else { return }
        draft = ""
        jax.type(text)
    }
}
