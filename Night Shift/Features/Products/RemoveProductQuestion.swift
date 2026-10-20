import SwiftUI

/// "Remove “…”?" — asked before a product leaves the list, wherever the command came from.
///
/// It used to act on the click. 14 Oct a product went with a run still working in it, and its chat
/// came back only by editing the app's files by hand. The question says where the chats go and
/// whether something is running; the notice after it offers Undo.
struct RemoveProductQuestion: ViewModifier {
    @Environment(AppModel.self) private var model

    private var product: Product? { model.products.product(id: model.removingProductID) }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text(String(format: String(localized: "Remove “%@”?"), product?.name ?? "")),
            isPresented: Binding(get: { product != nil },
                                 set: { if !$0 { model.removingProductID = nil } }),
            titleVisibility: .visible,
            presenting: product
        ) { product in
            Button("Remove", role: .destructive) {
                model.removingProductID = nil
                model.removeProduct(product)
            }
            Button("Cancel", role: .cancel) { model.removingProductID = nil }
        } message: { product in
            Text(model.removalNote(for: product))
        }
    }
}
