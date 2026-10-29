PrismJS 1.30.0 core and the clike, Solidity and V language definitions are copied unchanged from the npm `prismjs` package. They are copyright Lea Verou and contributors and distributed under the MIT license in `LICENSE`.

`runner.js` is LacEditor's adapter for UTF-16 token ranges. It calls the public `Prism.tokenize` API without a DOM and verifies that the token text reconstructs the input. Source code is data; no editor, themes or network code are loaded.

Source: https://github.com/PrismJS/prism/tree/v1.30.0
