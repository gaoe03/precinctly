/// Tracks one active address-resolution request so an older canceled search cannot publish over
/// a newer query or clear its loading state.
struct SearchResolutionGate {
    struct Receipt: Equatable {
        fileprivate let token: UInt
    }

    private var nextToken: UInt = 0
    private(set) var activeToken: UInt?

    mutating func begin() -> UInt {
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    func isCurrent(_ token: UInt) -> Bool {
        activeToken == token
    }

    func complete(_ token: UInt) -> Receipt? {
        guard isCurrent(token) else { return nil }
        return Receipt(token: token)
    }

    mutating func consume(_ receipt: Receipt) -> Bool {
        finish(receipt.token)
    }

    mutating func finish(_ token: UInt) -> Bool {
        guard isCurrent(token) else { return false }
        activeToken = nil
        return true
    }

    mutating func cancel() {
        activeToken = nil
    }
}
