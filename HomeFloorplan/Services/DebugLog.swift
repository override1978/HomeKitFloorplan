import Foundation

/// Stampa messaggi di debug solo nelle build DEBUG.
/// In Release (App Store / TestFlight) il corpo è vuoto e la funzione viene ottimizzata via.
@inline(__always)
func dprint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    print(output, terminator: terminator)
#endif
}
