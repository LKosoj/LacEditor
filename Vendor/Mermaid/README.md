# Mermaid 12.2.0 DOMPurify security rebuild

This is a one-time author build process, not an Xcode phase or part of the application build.

## Source and override

- Upstream: `mermaid-js/mermaid`, tag `mermaid@12.2.0`, commit `1fb7869866dd619168d840291c9c54b4f129758b`.
- Official npm baseline: https://registry.npmjs.org/mermaid/-/mermaid-12.2.0.tgz, integrity `sha512-w7nr/SFrLO7BaVTs3dQTvYSV6nYSBj0Yy9DjBhsIJtAcHqRzXSq4Pg32ujHZ/AdWsAMNEvvhbm5dt9E2tOiHzw==`, archive SHA256 `071914164d0f6d53e5c26a10a220230d4ae8d37ed0f2263fbf072266f0af3a0a`.
- The only manifest change is the existing root pnpm override `dompurify: 3.4.12` -> `dompurify: 3.4.17`. The exact modified root `package.json` and generated `pnpm-lock.yaml` are stored here. The lock diff changes only DOMPurify and its integrity.
- DOMPurify 3.4.17: https://registry.npmjs.org/dompurify/-/dompurify-3.4.17.tgz, integrity `sha512-B/pSlYVHQ58kqISD/yDjuJ1yfzI34m1gF4lAod2bwSRhiN4K5Cl3H8Af7hqB2PmTL911tdEudnnXn5FnhRoz0w==`.

DOMPurify 3.4.17 fixes the five advisories present in the bundled 3.4.12: `GHSA-55q2-fjhq-7xh7`, `GHSA-6688-9rhm-gjv2`, `GHSA-c6gr-qvv4-5v3f`, `GHSA-cg2g-xh64-v4q7`, and `GHSA-mrv2-3pqr-j5jr`.

## Bundled license notices

The regenerator-runtime notice in `mermaid.min.js` points to `packages/babel-helpers/LICENSE`. `REGENERATOR-RUNTIME-LICENSE.txt` is the unchanged official file from Babel v7.29.7, commit `4fba7541180bf5f58256d8e358b544e3831ad090`; the v7.28.4 file is byte-identical. SHA256: `4be9d87b56a306293223b490c0d0b245e9e94f39884147bf051a6c7b825aeb30`.

## Toolchain and author process

Verified with Node.js 24.21.0, upstream-pinned pnpm 10.30.3, and esbuild 0.25.12 from the lockfile. From a checkout of the tag above, copy this directory's `package.json` and `pnpm-lock.yaml` to its root, then run with local Corepack/pnpm caches:

```sh
corepack enable --install-directory "$PWD/.bin" pnpm
export PATH="$PWD/.bin:$PATH"
pnpm install --frozen-lockfile --ignore-scripts
pnpm build:mermaid
```

Use `packages/mermaid/dist/mermaid.min.js` unchanged. Do not edit the minified bundle manually. Two consecutive author builds produced SHA256 `c7aa95815786d2f43c235632f84d978dab71fca9f7c67e639a4bd74727f63ece`.

The application resource and this provenance directory are independent: Swift/Xcode never runs pnpm or downloads Mermaid during an application build.
