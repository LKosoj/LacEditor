# Mermaid 12.2.0

Unmodified `dist/mermaid.min.js` and `LICENSE` from the official npm package:
https://registry.npmjs.org/mermaid/-/mermaid-12.2.0.tgz

The package integrity was checked against the registry metadata:
`sha512-w7nr/SFrLO7BaVTs3dQTvYSV6nYSBj0Yy9DjBhsIJtAcHqRzXSq4Pg32ujHZ/AdWsAMNEvvhbm5dt9E2tOiHzw==`.
Package SHA-256: `071914164d0f6d53e5c26a10a220230d4ae8d37ed0f2263fbf072266f0af3a0a`.
Bundle SHA-256: `a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f`.

This is the self-contained IIFE build. It does not need ESM chunks or downloads
while the app runs. Preserve its bundled third-party license comments.
The library is MIT licensed; the original license is included in this folder.
The bundle's source map identifies its included `elkjs` as version 0.9.3.
Its EPL-2.0 license is also included (`ELK-LICENSE.md`); corresponding source:
https://github.com/kieler/elkjs/tree/v0.9.3 and
https://registry.npmjs.org/elkjs/-/elkjs-0.9.3.tgz.

`render.js` is LacEditor's own preview integration, executed in WebKit's
isolated client world. Diagram source is data, not JavaScript. Document scripts
stay disabled and the page's resource restrictions stay in place.

When updating Mermaid, pin the package version, verify the published integrity,
refresh the original license and bundle, and run preview tests, including
offline rendering, invalid syntax, themes, stale renders and document isolation.
