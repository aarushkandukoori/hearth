# Pie for Swift (vendored)

Pie's own Swift package, `PieServer` (the in-process Metal engine) and
`PieClient`, copied unchanged from
[pie-project/pie `packages/swift`](https://github.com/pie-project/pie/tree/6168f025d/packages/swift)
at commit `6168f025d`, under Pie's Apache 2.0 license (`LICENSE`, `NOTICE`).
Only `Package.swift` is trimmed to the two products Hearth links.

`build/PieServerCore.xcframework` is not in git (the iPhone library is about
290 MB). Make it with `ios/scripts/build-pie.sh`.
