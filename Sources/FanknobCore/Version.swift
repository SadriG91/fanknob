// Version.swift — the single source of truth for fanknob's version.
//
// Everything derives from this constant: the Makefile reads it to name the
// installer package, `make app` stamps it into the bundle's Info.plist, and the
// release workflow refuses to build a tag that disagrees with it. Bump it here
// and nowhere else.

/// Marketing version, matching the `vX.Y.Z` release tag.
public let fanknobVersion = "1.4.3"

/// Numeric component-wise comparison of `X.Y.Z` version strings (a leading
/// "v" is ignored, missing components count as 0). String comparison is not
/// enough here for the same reason CFBundleVersion needs care: "13" would
/// sort after "1.4.0" lexically in some schemes and before it in others.
public func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    func components(_ version: String) -> [Int] {
        var text = version
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = components(candidate)
    let b = components(current)
    for index in 0..<max(a.count, b.count) {
        let x = index < a.count ? a[index] : 0
        let y = index < b.count ? b[index] : 0
        if x != y { return x > y }
    }
    return false
}
