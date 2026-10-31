# Local flow and sequence renderers

The bundled files are unmodified release artifacts:

- flowchart.js 1.18.1, `release/flowchart.min.js`: https://github.com/adrai/flowchart.js/tree/v1.18.1 (MIT; FLOWCHART-LICENSE.txt).
- Raphaël 2.3.0, `raphael.min.js`: https://www.npmjs.com/package/raphael/v/2.3.0 (MIT; RAPHAEL-LICENSE.txt). Its bundled Eve 0.5.0 is Copyright 2013 Adobe Systems Incorporated, authored by Dmitry Baranovskiy (Apache 2.0; EVE-LICENSE.txt).
- Snap.svg 0.4.1, `dist/snap.svg-min.js`: https://github.com/adobe-webplatform/Snap.svg/tree/v0.4.1 (Apache 2.0; SNAP-LICENSE.txt).
- Underscore 1.13.8, `underscore-min.js`: https://www.npmjs.com/package/underscore/v/1.13.8 (MIT; UNDERSCORE-LICENSE.txt).
- js-sequence-diagrams 2.0.1, `dist/sequence-diagram-snap-min.js`: https://github.com/bramp/js-sequence-diagrams/tree/v2.0.1 (BSD-2-Clause; SEQUENCE-LICENSE.txt).
- Daniel Bold, `fonts/daniel/danielbd-original.ttf` from the same sequence archive, distributed unchanged with DANIEL-NOTICE.txt. Upstream describes a backslash glyph defect in this original font; its modified WOFF and Cufon conversions are not included.

Underscore 1.13.8 comes from npm release commit `4a4019e00beb2c42eda20c05f375a35983b748f0`. The npm tarball integrity is `sha512-DXtD3ZtEQzc7M8m4cXotyHR+FAS18C64asBYY5vqZexfYryNNnDc02W4hKg3rdQuqOYas1jkseX0+nZXjTXnvQ==`. SHA256 is `89e99999dfa83ee9fb88e58beb7820961dbfcf391cee2f361ffd4a3489309c69` for `underscore-min.js` and `92905fb54f5d168a27e6d5dc7c2197020add11842be4c70689d084bae3bfe37a` for `UNDERSCORE-LICENSE.txt`.

`vendored-package-lock.json` is a custom OSV-Scanner inventory of the vendored JavaScript, not an npm installation manifest. Registry coordinates enable vulnerability matching and do not replace the artifact provenance listed above. The sole exception in `osv-scanner.toml` covers only `MAL-2025-23922` until 2027-01-31. Before scanning, CI verifies that the local `sequence-diagram-snap-min.js` has SHA256 `115a5a788eb973e7769a5473c6c9c9b7559f4159016745c229a9e3fae23cf7a8` and is byte-identical to the artifact at bramp/js-sequence-diagrams commit `a6c252b2ed0d1e6b1d16be066f582afd2895e6c9`. This exception is not a waiver for the `js-sequence-diagrams` npm package, which OSV marks as malicious.

The workflow also scans both Swift `Package.resolved` files. Current OSV-Scanner extraction is version-based for Swift: the revision-only Yams and SwiftSoup pins are not vulnerability-matched, so a clean scan does not cover those two dependencies.
