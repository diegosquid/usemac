import Foundation

/// Gives each task in the live preview its own color, so two sessions of the same agent can be told apart.
///
/// A color is a slot in a fixed palette of `paletteSize` (the app owns the actual colors). A task keeps its slot
/// while any of its cards is in the deck and frees it when the last one leaves, and a new task takes the lowest free
/// slot. Cards whose task UseMac could not tell get a slot of their own.
public enum PreviewTaskColors {
    public static let paletteSize = 6

    /// The key a card is colored by: its task, or the card itself when it has no task.
    public static func key(taskId: String?, cardId: String) -> String {
        if let taskId, !taskId.isEmpty { return "task:\(taskId)" }
        return "card:\(cardId)"
    }

    /// The slots after the deck changed. `keys` are the deck's card keys in deck order (a task with several cards
    /// appears several times). Keys still in the deck keep their slot, keys that left free theirs, and new keys take
    /// the lowest free slot. With every slot taken, a new key shares one, picked by how many keys there are.
    public static func reconcile(_ current: [String: Int], keys: [String]) -> [String: Int] {
        let present = Set(keys)
        var slots = current.filter { present.contains($0.key) }
        for key in keys where slots[key] == nil {
            let used = Set(slots.values)
            slots[key] = (0..<paletteSize).first(where: { !used.contains($0) }) ?? (slots.count % paletteSize)
        }
        return slots
    }
}
