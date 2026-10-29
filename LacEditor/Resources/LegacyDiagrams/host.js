'use strict';
window.renderDiagram = async function(source, kind, theme, width) {
  const container = document.getElementById('diagram');
  container.replaceChildren();
  if (kind === 'flow') {
    flowchart.parse(source).drawSVG(container);
  } else if (kind === 'sequence' && (theme === 'simple' || theme === 'hand')) {
    if (theme === 'hand') {
      const fonts = await document.fonts.load('16px danielbd');
      if (!fonts.length) throw new Error('Diagram font unavailable');
    }
    window.WebFont = { load: options => options.active() };
    Diagram.parse(source).drawSVG(container, {theme});
  } else throw new Error('Unsupported diagram');
  await document.fonts.ready;
  const svg = container.querySelector('svg');
  if (!svg || container.querySelectorAll('svg').length !== 1) throw new Error('Diagram unavailable');
  const box = svg.getBBox();
  if (![box.x, box.y, box.width, box.height, width].every(Number.isFinite) || box.width <= 0 || box.height <= 0 || width <= 0) throw new Error('Invalid diagram bounds');
  const root = svg.getScreenCTM();
  if (!root) throw new Error('Missing transform');
  const inverse = root.inverse();
  let left = box.x, top = box.y, right = box.x + box.width, bottom = box.y + box.height;
  for (const element of svg.querySelectorAll('path,rect,circle,ellipse,line,polyline,polygon,text,use')) {
    if (element.closest('defs')) continue;
    const matrix = element.getScreenCTM();
    if (!matrix) throw new Error('Missing element transform');
    const transform = inverse.multiply(matrix), bounds = element.getBBox();
    const points = [[bounds.x,bounds.y],[bounds.x+bounds.width,bounds.y],
                    [bounds.x,bounds.y+bounds.height],[bounds.x+bounds.width,bounds.y+bounds.height]]
      .map(([x,y]) => new DOMPoint(x,y).matrixTransform(transform));
    const style = getComputedStyle(element);
    const stroke = style.stroke === 'none' ? 0 : Number.parseFloat(style.strokeWidth);
    const miter = style.strokeLinejoin === 'miter' ? Math.max(1, Number.parseFloat(style.strokeMiterlimit) || 1) : 1;
    const radius = stroke * miter / 2;
    const padX = radius * Math.hypot(transform.a, transform.c), padY = radius * Math.hypot(transform.b, transform.d);
    left = Math.min(left, ...points.map(p => p.x - padX));
    right = Math.max(right, ...points.map(p => p.x + padX));
    top = Math.min(top, ...points.map(p => p.y - padY));
    bottom = Math.max(bottom, ...points.map(p => p.y + padY));
  }
  if (![left, top, right, bottom].every(Number.isFinite)) throw new Error('Invalid painted bounds');
  const padding = 4, w = right - left + 2 * padding, h = bottom - top + 2 * padding;
  const displayedWidth = Math.min(width, w), displayedHeight = h * displayedWidth / w;
  svg.setAttribute('viewBox', `${left - padding} ${top - padding} ${w} ${h}`);
  svg.setAttribute('width', String(displayedWidth));
  svg.setAttribute('height', String(displayedHeight));
  const rect = svg.getBoundingClientRect();
  if (![rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) || rect.width <= 0 || rect.height <= 0) throw new Error('Invalid output');
  return [rect.right, rect.bottom];
};
