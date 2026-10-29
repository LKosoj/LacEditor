// Prism tokenizes bundled grammars; source text is passed as an argument.
(function () {
  function source(name) {
    const value = readPrismModule(name);
    if (typeof value !== "string") throw new Error("missing module " + name);
    return value;
  }
  globalThis.prismTokens = function (language, text) {
    if (prismCancelled()) throw new Error("cancelled");
    const prism = new Function(source("prism-core") + "\n;return Prism;")();
    new Function("Prism", source("prism-clike"))(prism);
    new Function("Prism", source("prism-" + language))(prism);
    const grammar = prism.languages[language];
    if (!grammar) throw new Error("unsupported language");
    const nodes = prism.tokenize(text, grammar), tokens = [], pieces = [];
    let offset = 0;
    function walk(node, style) {
      if (prismCancelled()) throw new Error("cancelled");
      if (typeof node === "string") {
        if (style && node.length) tokens.push([offset, node.length, style]);
        pieces.push(node); offset += node.length;
      } else if (Array.isArray(node)) {
        for (const child of node) walk(child, style);
      } else if (node && typeof node.type === "string") {
        const alias = Array.isArray(node.alias) ? node.alias.join(" ") : (node.alias || "");
        walk(node.content, node.type + " " + alias + " " + style);
      } else throw new Error("invalid token");
    }
    walk(nodes, "");
    if (pieces.join("") !== text) throw new Error("text mismatch");
    return tokens;
  };
})();
