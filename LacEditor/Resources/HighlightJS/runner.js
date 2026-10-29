// highlight.js returns escaped HTML; only its fixed span tags are read here.
(function () {
  function module(id) {
    const source = readHighlightModule(id);
    if (typeof source !== "string") throw new Error("missing module " + id);
    const result = { exports: {} };
    new Function("module", "exports", source)(result, result.exports);
    return result.exports;
  }
  const entities = { amp: "&", lt: "<", gt: ">", quot: '"', "#x27": "'" };
  globalThis.highlightTokens = function (language, text) {
    if (highlightCancelled()) throw new Error("cancelled");
    const hl = module("core");
    if (language === "svelte") {
      for (const dependency of ["xml", "javascript", "css"]) hl.registerLanguage(dependency, module("languages/" + dependency));
      module("languages/svelte")(hl);
    } else hl.registerLanguage(language, module("languages/" + language));
    const html = hl.highlight(text, { language: language, ignoreIllegals: true }).value;
    if (highlightCancelled()) throw new Error("cancelled");
    const tokens = [], stack = []; let index = 0, decoded = "";
    while (index < html.length) {
      if (highlightCancelled()) throw new Error("cancelled");
      if (html.startsWith("</span>", index)) {
        if (!stack.length) throw new Error("invalid highlight markup");
        stack.pop(); index += 7; continue;
      }
      if (html.startsWith('<span class="', index)) {
        const end = html.indexOf('">', index + 13);
        if (end < 0) throw new Error("invalid highlight markup");
        const name = html.slice(index + 13, end).replace(/\bhljs-/g, "");
        stack.push(name); index = end + 2; continue;
      }
      const end = html.indexOf("<", index);
      const raw = html.slice(index, end < 0 ? html.length : end);
      const piece = raw.replace(/&(amp|lt|gt|quot|#x27);/g, (_, name) => entities[name]);
      if (stack.length && piece.length) tokens.push([decoded.length, piece.length, stack.join(" ")]);
      decoded += piece; index = end < 0 ? html.length : end;
      if (!raw.length) throw new Error("invalid highlight markup");
    }
    if (stack.length || decoded !== text) throw new Error("text mismatch");
    return tokens;
  };
})();
