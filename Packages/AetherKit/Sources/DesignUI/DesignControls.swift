import AetherDesign
import DesignCore
import SwiftUI

/// A field that changes the document when it's submitted (↩) or left, not
/// on each key: a step a word, not a step a letter.
struct CommitField: View {
    let title: String
    let value: String
    var axis: Axis = .horizontal
    var prompt: String?
    /// Bumped to put the keys in it.
    var focusRequest = 0
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: prompt.map { Text($0) }, axis: axis)
            .textFieldStyle(.roundedBorder)
            .font(.aeBody)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, now in if !focused { draft = now } }
            .onSubmit { commit(draft) }
            .onChange(of: focusRequest) { focused = true }
            .onChange(of: focused) { _, now in if !now, draft != value { commit(draft) } }
            .accessibilityLabel(title)
    }
}

/// A row of the inspector: a label, then its control.
struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 58, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// A token's swatch: its colour, or nothing.
struct Swatch: View {
    let color: NSColor?

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color.map(Color.init(nsColor:)) ?? .clear)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// A style's value, tokens first: a menu of the theme's tokens of the right
/// kind, then a field for a value as written. Nil says nothing.
struct TokenPicker: View {
    let label: String
    let kind: DesignTokenKind
    let value: String?
    let tokens: [DesignToken]
    let resolver: DesignResolver
    let set: (String?) -> Void

    private var fitting: [DesignToken] {
        var seen = Set<String>()
        return tokens.filter { resolver.kind(of: $0) == kind && seen.insert($0.name).inserted }
    }

    var body: some View {
        InspectorRow(label) {
            if kind == .color {
                Swatch(color: resolver.color(value))
            }
            Menu {
                ForEach(fitting) { token in
                    Button {
                        set(token.name)
                    } label: {
                        Text(verbatim: "\(token.name)  \(token.value)")
                    }
                }
                Divider()
                Button("None") { set(nil) }
            } label: {
                Text(verbatim: display)
                    .font(.aeMono)
                    .foregroundStyle(value?.hasPrefix("--") == true && !resolver.has(value ?? "") ? Color.coral : Color.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(value.map { resolver.has($0) || !$0.hasPrefix("--") ? $0 : "\($0) isn't in theme.css" } ?? "Not set")
            if value?.hasPrefix("--") != true {
                CommitField(title: "\(label) value", value: value ?? "", prompt: kind == .color ? "#rrggbb" : "value") { text in
                    let t = text.trimmingCharacters(in: .whitespaces)
                    set(t.isEmpty ? nil : t)
                }
                .frame(width: 90)
            }
        }
    }

    private var display: String {
        guard let value else { return "None" }
        return value.hasPrefix("--") ? value : "Custom"
    }
}

/// A length: a token of points, or a number.
struct LengthPicker: View {
    let label: String
    let value: DesignVal?
    let tokens: [DesignToken]
    let resolver: DesignResolver
    let set: (DesignVal?) -> Void

    private var fitting: [DesignToken] {
        var seen = Set<String>()
        return tokens.filter { resolver.kind(of: $0) == .length && seen.insert($0.name).inserted }
    }

    var body: some View {
        InspectorRow(label) {
            Menu {
                ForEach(fitting) { token in
                    Button { set(.text(token.name)) } label: { Text(verbatim: "\(token.name)  \(token.value)") }
                }
                Divider()
                Button("None") { set(nil) }
            } label: {
                Text(verbatim: value?.isToken == true ? value!.description : "pt")
                    .font(.aeMono)
                    .foregroundStyle(value?.isToken == true && !resolver.has(value?.word ?? "") ? Color.coral : Color.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if value?.isToken != true {
                CommitField(title: "\(label) points", value: value?.number.map { DesignVal.num($0).description } ?? "", prompt: "0") { text in
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { return set(nil) }
                    if let n = Double(t) { set(.num(max(0, n))) }
                }
                .frame(width: 60)
            } else if let points = resolver.length(value) {
                Text(verbatim: "\(DesignVal.num(points))").font(.aeSmall).foregroundStyle(Color.ink3)
            }
        }
    }
}

/// A width or a height: Hug, Fill or a number of points.
struct SizePicker: View {
    let label: String
    let value: DesignVal
    let set: (DesignVal?) -> Void

    private var mode: String {
        switch value {
        case .num: "fixed"
        case let .text(word): word
        }
    }

    var body: some View {
        InspectorRow(label) {
            Picker(label, selection: Binding(get: { mode }, set: { now in
                switch now {
                case "fixed": set(.num(value.number ?? 100))
                default: set(.text(now))
                }
            })) {
                Text("Hug").tag("hug")
                Text("Fill").tag("fill")
                Text("Fixed").tag("fixed")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            if case let .num(n) = value {
                CommitField(title: "\(label) points", value: DesignVal.num(n).description) { text in
                    if let n = Double(text.trimmingCharacters(in: .whitespaces)) { set(.num(max(0, n))) }
                }
                .frame(width: 56)
            }
        }
    }
}

/// One of a few words, as a segmented control.
struct WordPicker: View {
    let label: String
    let value: String
    let options: [(word: String, title: String)]
    let set: (String) -> Void

    var body: some View {
        InspectorRow(label) {
            Picker(label, selection: Binding(get: { value }, set: set)) {
                ForEach(options, id: \.word) { Text($0.title).tag($0.word) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
        }
    }
}
