import PhotonDesign
import DiffuseCore
import SwiftUI

/// The node library: every node type the server serves, by group. A click,
/// or Return on the first match, adds one where the pointer last was.
struct NodeLibraryPanel: View {
    @Bindable var model: DiffuseWorkspaceModel
    let library: NodeLibrary
    @State private var query = ""
    @FocusState private var searching: Bool

    private var groups: [(name: String, nodes: [NodeType])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return library.catalogue.groups }
        return library.catalogue.groups.compactMap { group in
            let nodes = group.nodes.filter { $0.title.lowercased().contains(q) || $0.type.lowercased().contains(q) || group.name.lowercased().contains(q) }
            return nodes.isEmpty ? nil : (group.name, nodes)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.ink2)
                TextField("Find a node", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                    .onSubmit {
                        if let first = groups.first?.nodes.first { add(first) }
                    }
                Text("⇥").font(.aeMono).foregroundStyle(Color.ink2)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.button).fill(Color.raise1))
            .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(searching ? Color.ice : Color.line2))
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups, id: \.name) { group in
                        Text(group.name)
                            .font(.aeLabel)
                            .foregroundStyle(Color.ink2)
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(group.nodes) { node in
                            LibraryRow(node: node) { add(node) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }

            HStack(spacing: 6) {
                Circle().fill(library.source == .builtIn ? Color.amber : Color.live).frame(width: 6, height: 6)
                Text(library.source.label).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
        }
        .aeGlass()
        .onChange(of: model.searchRequest) { searching = true }
        .onAppear { searching = true }
    }

    private func add(_ node: NodeType) {
        model.addNode(node.type, at: model.pointer)
        query = ""
    }
}

private struct LibraryRow: View {
    let node: NodeType
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: GroupStyle.symbol(node.group)).font(.system(size: 11)).foregroundStyle(Color.ink2).frame(width: 16)
                Text(node.title).font(.system(size: 12)).foregroundStyle(Color.ink)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(Array(node.outputs.prefix(3).enumerated()), id: \.offset) { _, output in
                        Circle().fill(SocketStyle.color(output.type)).frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(node.title) · makes \(node.outputs.map(\.type).joined(separator: ", ").ifEmpty("pictures"))")
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
