// Version.swift — the single source of truth for fanknob's version.
//
// Everything derives from this constant: the Makefile reads it to name the
// installer package, `make app` stamps it into the bundle's Info.plist, and the
// release workflow refuses to build a tag that disagrees with it. Bump it here
// and nowhere else.

/// Marketing version, matching the `vX.Y.Z` release tag.
public let fanknobVersion = "1.4.2"
