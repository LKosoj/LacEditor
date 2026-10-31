# Mermaid 12.2.0 with DOMPurify 3.4.17

The self-contained IIFE bundle is built from official `mermaid@12.2.0` source at commit `1fb7869866dd619168d840291c9c54b4f129758b`, with only the existing pnpm override changed from DOMPurify 3.4.12 to 3.4.17. It is not the byte-identical npm 12.2.0 bundle and was not edited manually after the official build. The exact author process, toolchain, package manifest, and lockfile are in `Vendor/Mermaid`.

Official npm 12.2.0 baseline: https://registry.npmjs.org/mermaid/-/mermaid-12.2.0.tgz
Integrity: `sha512-w7nr/SFrLO7BaVTs3dQTvYSV6nYSBj0Yy9DjBhsIJtAcHqRzXSq4Pg32ujHZ/AdWsAMNEvvhbm5dt9E2tOiHzw==`.
Package SHA-256: `071914164d0f6d53e5c26a10a220230d4ae8d37ed0f2263fbf072266f0af3a0a`.
Rebuilt bundle SHA-256: `c7aa95815786d2f43c235632f84d978dab71fca9f7c67e639a4bd74727f63ece`.

DOMPurify 3.4.17 is the latest npm release and returns no OSV vulnerabilities. Its package integrity is `sha512-B/pSlYVHQ58kqISD/yDjuJ1yfzI34m1gF4lAod2bwSRhiN4K5Cl3H8Af7hqB2PmTL911tdEudnnXn5FnhRoz0w==`. Its dual Apache-2.0/MPL-2.0 licenses are included as `DOMPURIFY-LICENSE.txt` and `DOMPURIFY-LICENSE-MPL.txt`.

The bundle needs no ESM chunks or downloads while the app runs. Preserve its bundled third-party license comments. Mermaid is MIT licensed; its original `LICENSE` is unchanged. The bundle's source map identifies `elkjs` 0.9.3, whose EPL-2.0 license is included (`ELK-LICENSE.md`); corresponding source: https://github.com/kieler/elkjs/tree/v0.9.3 and https://registry.npmjs.org/elkjs/-/elkjs-0.9.3.tgz.

`render.js` is LacEditor's own preview integration, executed in WebKit's
isolated client world. Diagram source is data, not JavaScript. Document scripts
stay disabled and the page's resource restrictions stay in place.

When updating Mermaid, pin the package version, verify the published integrity,
refresh the original license and bundle, and run preview tests, including
offline rendering, invalid syntax, themes, stale renders and document isolation.
