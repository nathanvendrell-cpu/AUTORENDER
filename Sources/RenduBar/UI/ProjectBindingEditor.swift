import SwiftUI

struct ProjectBindingEditor: View {
    @ObservedObject var model: MonitorModel
    let original: RenderProjectBinding
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var roots: [RenderProjectRoot]
    @State private var message = ""
    init(model: MonitorModel, binding: RenderProjectBinding) {
        self.model = model; original = binding
        _title = State(initialValue: binding.title); _roots = State(initialValue: binding.roots)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Corriger la liaison du projet").font(.system(size: 20, weight: .semibold))
            TextField("Nom affiché", text: $title).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(roots.indices), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Source : " + roots[index].namespace).font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
                            TextField("Racine exacte", text: Binding(get: { roots[index].path }, set: { roots[index] = RenderProjectRoot(path: $0, namespace: roots[index].namespace) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }.frame(maxHeight: 240)
            Text("L’identité du projet et la source de chaque racine restent inchangées. Cette correction modifie le catalogue, sans déplacer les anciens médias.")
                .font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("Rétablir les valeurs à l’ouverture") { title = original.title; roots = original.roots }
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer la correction") {
                    var bindings = model.config.projectBindings ?? []
                    guard let index = bindings.firstIndex(where: { $0.id == original.id }) else { message = "Liaison désormais indisponible."; return }
                    bindings[index] = RenderProjectBinding(id: original.id, title: title, roots: roots)
                    if model.setProjectBindings(bindings) { dismiss() }
                    else { message = model.organizationError ?? "Correction non enregistrée." }
                }.buttonStyle(.borderedProminent).disabled(model.libraryBusy)
            }
        }.padding(22).frame(width: 640).foregroundStyle(RenderStyle.ink).renderWindowSurface()
    }
}
