// This code runs in WebKit's application-owned content world, never in the page world.
globalThis.lacMermaid = (() => {
  let generation = -1;
  let queue = Promise.resolve();
  let nextID = 0;

  function invalidate(value) {
    generation = Math.max(generation, value);
  }

  async function render(value, dark, errorText) {
    invalidate(value);
    const work = async () => {
      if (generation !== value) return;
      const article = document.querySelector('article');
      if (!article) return;
      const blocks = Array.from(article.querySelectorAll('pre > code.language-mermaid'));
      if (!blocks.length) return;
      const root = document.documentElement;
      const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
      const ratio = maximum > 0 ? window.scrollY / maximum : 0;
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        htmlLabels: false,
        flowchart: { htmlLabels: false },
        secure: ['secure', 'securityLevel', 'startOnLoad', 'htmlLabels', 'flowchart',
                 'theme', 'themeVariables', 'fontFamily', 'dompurifyConfig',
                 'maxTextSize', 'maxEdges', 'suppressErrorRendering'],
        theme: dark ? 'dark' : 'default'
      });
      for (const code of blocks) {
        if (generation !== value || !article.isConnected || !code.isConnected) return;
        const pre = code.parentElement;
        let output = pre.nextElementSibling;
        if (!output || !output.classList.contains('mermaid-diagram')) {
          output = document.createElement('div');
          output.className = 'mermaid-diagram';
          pre.after(output);
        }
        const horizontal = output.scrollLeft;
        const scratch = document.createElement('div');
        document.body.append(scratch);
        try {
          const result = await mermaid.render('lac-mermaid-' + (++nextID), code.textContent, scratch);
          if (generation !== value || !article.isConnected || !code.isConnected) return;
          output.innerHTML = result.svg;
          output.removeAttribute('role');
          pre.hidden = true;
          output.scrollLeft = horizontal;
        } catch (_) {
          if (generation !== value || !article.isConnected || !code.isConnected) return;
          output.textContent = errorText;
          output.setAttribute('role', 'alert');
          pre.hidden = false;
        } finally {
          scratch.remove();
        }
      }
      if (generation === value && article.isConnected) {
        window.scrollTo(0, Math.max(0, Math.min(1, ratio)) * Math.max(0, root.scrollHeight - window.innerHeight));
      }
    };
    queue = queue.catch(() => {}).then(work);
    return queue;
  }

  return { invalidate, render };
})();
