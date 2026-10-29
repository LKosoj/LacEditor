'use strict';
const lacMathOptions = window.lacMathOptions || { physics: true, tags: 'none' };
window.MathJax = {
  loader: {
    paths: { tex: './input/tex/extensions', fonts: '.' },
    load: ['[tex]/mhchem', ...(lacMathOptions.physics ? ['[tex]/physics'] : [])]
  },
  startup: { typeset: false },
  options: { enableSpeech: false, enableBraille: false, menuOptions: { settings: { enrich: false, speech: false, braille: false } } },
  tex: {
    packages: { '[+]': ['mhchem', ...(lacMathOptions.physics ? ['physics'] : [])] },
    tags: lacMathOptions.tags,
    autoload: { html: [] },
    require: { defaultAllow: false, allow: {
      action: true, ams: true, amscd: true, bbm: true, bboldx: true, bbox: true,
      begingroup: true, boldsymbol: true, braket: true, bussproofs: true, cancel: true,
      cases: true, centernot: true, color: true, colortbl: true, colorv2: true,
      dsfont: true, empheq: true, enclose: true, extpfeil: true, fontsizev3: true,
      gensymb: true, mathtools: true, mhchem: true, newcommand: true, physics: true,
      textcomp: true, textmacros: true, unicode: true, units: true, upgreek: true, verb: true
    } }
  },
  svg: { font: 'mathjax-tex', fontCache: 'local' }
};
