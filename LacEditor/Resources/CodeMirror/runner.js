// Loads only bundled CodeMirror modules. Document text is passed to runMode as data.
(function () {
  const cache = Object.create(null);
  function resolve(from, request) {
    if (request === "../../lib/codemirror" || request === "../lib/codemirror" ||
        request === "./runmode.node" || request === "../../addon/runmode/runmode") return "core";
    if (!request.startsWith(".")) throw new Error("unsupported module");
    const parts = from.split("/"); parts.pop();
    for (const part of request.split("/")) {
      if (part === "." || part === "") continue;
      if (part === "..") { if (!parts.length) throw new Error("invalid module"); parts.pop(); }
      else parts.push(part);
    }
    return parts.join("/");
  }
  function load(id) {
    if (cache[id]) return cache[id].exports;
    const source = readCodeMirrorModule(id);
    if (typeof source !== "string") throw new Error("missing module " + id);
    const module = { exports: {} }; cache[id] = module;
    function require(request) { return load(resolve(id, request)); }
    require.resolve = function (request) { return resolve(id, request); };
    require.cache = cache;
    try { new Function("require", "module", "exports", source)(require, module, module.exports); }
    catch (error) { delete cache[id]; throw error; }
    return module.exports;
  }
  globalThis.codeMirrorTokens = function (moduleName, mime, text) {
    const cm = load("core");
    load("mode/" + moduleName + "/" + moduleName);
    if (moduleName === "htmlembedded") {
      load("mode/clike/clike");
      load("mode/ruby/ruby");
    }
    const getMode = cm.getMode;
    if (getMode(cm.defaults, mime).name === "null") throw new Error("unsupported language");
    cm.getMode = function (options, spec) {
      const mode = getMode(options, spec);
      const token = mode.token;
      let stalled = null;
      mode.token = function (stream, state) {
        if (codeMirrorCancelled()) throw new Error("cancelled");
        const start = stream.pos, style = token.call(mode, stream, state);
        if (stream.pos <= start) {
          const current = JSON.stringify(state);
          if (current === stalled) throw new Error("mode did not advance: " + mode.name);
          stalled = current;
        } else stalled = null;
        return style;
      };
      return mode;
    };
    const tokens = []; let offset = 0, checks = 0;
    try {
      cm.runMode(text, mime, function (piece, style) {
        if ((checks++ & 255) === 0 && codeMirrorCancelled()) throw new Error("cancelled");
        if (style) tokens.push([offset, piece.length, style]);
        offset += piece.length;
      });
    } finally { cm.getMode = getMode; }
    if (offset !== text.length) throw new Error("text mismatch");
    return tokens;
  };
})();
