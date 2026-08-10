/// Carries a non-`Sendable` value across a continuation boundary.
///
/// Virtualization's completion handlers hand back objects such as
/// `VZMacOSRestoreImage` that are not `Sendable`, so resuming a continuation
/// with one directly is rejected under Swift 6. The objects are in fact used
/// from a single actor on both sides of the hop, so the box makes that promise
/// explicit at exactly the point where it is being made, rather than
/// suppressing concurrency checking across a whole type.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
