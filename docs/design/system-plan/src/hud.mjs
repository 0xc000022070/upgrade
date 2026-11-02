// Rebuilds boards B12 (mascot) and B13 (texture) inside v2/upgrade-app.pen.
// Usage: node hud.mjs <in.pen> <out.pen>
import fs from 'node:fs';

const C = { t1: '#E8E8E3', t2: '#9A9FA6', t3: '#6F767F', t4: '#50555C', sig: '#FF5A1F', gold: '#D9A93A', panel: '#0B0D10', b2: '#2E343C', s1: '#111317', tex: '#1C2026', texHot: '#3A1A10', black: '#000000' };
const MONO = 'IBM Plex Mono', SANS = 'IBM Plex Sans', COND = 'Barlow Condensed';
let seq = 0;
const nid = (p) => `h${p}${(seq++).toString(36)}`;

const F = (o, children = []) => ({ type: 'frame', id: nid('f'), layout: 'vertical', ...o, children: children.filter(Boolean) });
const H = (o, ch) => F({ layout: 'horizontal', ...o }, ch);
const T = (content, o = {}) => ({
  type: 'text', id: nid('t'), content, fontFamily: o.font ?? MONO, fontSize: o.size ?? 11, fill: o.color ?? C.t1,
  ...(o.weight && { fontWeight: String(o.weight) }), ...(o.ls && { letterSpacing: o.ls }), ...(o.lh && { lineHeight: o.lh }),
  ...(o.w && { width: o.w, textGrowth: 'fixed-width' }),
});
const at = (x, y, node) => ({ ...node, x, y });
const cap = (s, c = C.t3) => T(s.toUpperCase(), { size: 9.5, color: c, ls: 1.2 });
const panel = (o, ch) => F({ padding: [24, 24], gap: 14, fill: C.panel, stroke: C.b2, strokeWidth: 1, alignItems: 'center', justifyContent: 'center', ...o }, ch);

// every drawing lives in a 100x100 box; stroke widths are in pixels at the drawn size
const path = (size, d, o) => ({ type: 'path', id: nid('p'), x: 0, y: 0, width: size, height: size, viewBox: [0, 0, 100, 100], geometry: d, ...o });
const strokeP = (size, d, color, px) => path(size, d, { stroke: color, strokeWidth: px, strokeLinecap: 'butt', strokeLinejoin: 'miter' });
const fillP = (size, d, color) => path(size, d, { fill: color });

const rad = (deg) => (deg * Math.PI) / 180;
const pt = (cx, cy, r, deg) => [cx + r * Math.cos(rad(deg)), cy + r * Math.sin(rad(deg))];
const f2 = (v) => v.toFixed(2);
function arc(cx, cy, r, from, sweep) {
  const [x0, y0] = pt(cx, cy, r, from), [x1, y1] = pt(cx, cy, r, from + sweep);
  return `M${f2(x0)} ${f2(y0)}A${r} ${r} 0 ${sweep > 180 ? 1 : 0} 1 ${f2(x1)} ${f2(y1)}`;
}
const radial = (cx, cy, r0, r1, deg) => { const [a, b] = pt(cx, cy, r0, deg), [c, d] = pt(cx, cy, r1, deg); return `M${f2(a)} ${f2(b)}L${f2(c)} ${f2(d)}`; };
const disc = (x, y, r) => `M${f2(x - r)} ${f2(y)}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0Z`;
const line = (a, b) => `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`;

// the jet from the footage, in planform, nose up; right half only, mirrored
const JET_HALF = [[0, -46], [2.4, -37], [3.8, -25], [4.4, -9], [9, -1], [30, 10], [31, 9], [31.5, 17], [8, 19], [8, 25], [20, 36], [20, 40], [6.5, 40], [4.5, 45], [0, 45]];
const HEADING = -55, SCALE = 0.5;
function jetD(cx = 50, cy = 50, scale = SCALE, heading = HEADING) {
  const r = rad(heading + 90), c = Math.cos(r), s = Math.sin(r);
  const pts = [...JET_HALF, ...JET_HALF.slice(1, -1).reverse().map(([x, y]) => [-x, y])];
  return pts.map(([x, y], i) => `${i ? 'L' : 'M'}${f2(cx + (x * c - y * s) * scale)} ${f2(cy + (x * s + y * c) * scale)}`).join('') + 'Z';
}
// the arc's gap opens where the nose points; the trail leaves the tail and runs off the frame
const GAP = 64, GAP_END = HEADING + GAP / 2;
function trailD(len = 60, off = 0) {
  const u = [Math.cos(rad(HEADING)), Math.sin(rad(HEADING))], n = [-u[1], u[0]];
  const tail = [50 - u[0] * 22 + n[0] * off, 50 - u[1] * 22 + n[1] * off];
  return line(tail, [tail[0] - u[0] * len, tail[1] - u[1] * len]);
}

export function jet(size, st = 'idle', o = {}) {
  const px = Math.max(1, size / 46), main = st === 'asks' ? C.sig : st === 'sleep' ? C.t4 : C.t1;
  const sweep = st === 'working' ? 140 : st === 'done' ? 360 : 360 - GAP;
  const kids = [];
  if (st !== 'sleep' && o.ring !== false) {
    kids.push(strokeP(size, sweep === 360 ? `${arc(50, 50, 36, 0, 180)}${arc(50, 50, 36, 180, 180).replace('M', 'L')}` : arc(50, 50, 36, GAP_END, sweep), main, Math.max(1.2, px * 0.6)));
    if (sweep < 360) kids.push(strokeP(size, radial(50, 50, 36, 30, GAP_END + sweep), main, Math.max(1.2, px * 0.6)));
  }
  if (st !== 'sleep' && o.trail !== false) kids.push(strokeP(size, trailD(o.long ? 70 : 52), st === 'working' ? C.t1 : C.t3, px * 0.8), strokeP(size, trailD(o.long ? 70 : 52, 3.2), st === 'working' ? C.t1 : C.t3, px * 0.5));
  // with nothing around it the jet fills the box
  const d = o.ring === false && o.trail === false ? jetD(50, 50, 1.02) : jetD();
  kids.push(st === 'sleep' ? strokeP(size, d, C.t4, px * 0.9) : fillP(size, d, main));
  if (st === 'asks') kids.push(strokeP(size, 'M50 22L78 50L50 78L22 50Z', C.sig, px));
  return F({ layout: 'none', width: size, height: size, clip: true }, kids);
}

// gun-camera film grain: hashed dots, denser toward one corner
function grain(w, h, step, color, density = (x, y) => 0.5) {
  let d = '', s = 7;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  for (let y = step / 2; y < h; y += step) for (let x = step / 2; x < w; x += step) if (rnd() < density(x / w, y / h)) d += disc(x + (rnd() - 0.5) * step * 0.6, y + (rnd() - 0.5) * step * 0.6, step * 0.16);
  return { type: 'path', id: nid('p'), x: 0, y: 0, width: w, height: h, viewBox: [0, 0, w, h], geometry: d || 'M0 0', fill: color };
}

// heading tape: ticks every 5 units, numbers every 10
function tape(w, color, from = 25) {
  const kids = [];
  let d = '';
  for (let i = 0, x = 6; x < w; i++, x += 18) {
    d += `M${x} 0V${i % 2 ? 4 : 8}`;
    if (!(i % 2)) kids.push(at(x - 6, 12, T(String(from + i / 2).padStart(2, '0'), { size: 9, color })));
  }
  return F({ layout: 'none', width: w, height: 26 }, [{ type: 'path', id: nid('p'), x: 0, y: 0, width: w, height: 8, viewBox: [0, 0, w, 8], geometry: d, stroke: color, strokeWidth: 1 }, ...kids]);
}

// footage look: grainy grey sky with soft cloud blotches and a vignette, the jet dark against it
function noise2(x, y, seed) {
  const h = (i, j) => { let n = (i * 374761393 + j * 668265263 + seed * 2147483647) | 0; n = Math.imul(n ^ (n >>> 13), 1274126177); return ((n ^ (n >>> 16)) >>> 0) / 4294967295; };
  const xi = Math.floor(x), yi = Math.floor(y), fx = x - xi, fy = y - yi, sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
  const a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1);
  return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy;
}
function sky(w, h, step, o = {}) {
  let s = 11;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const tones = [[o.lo ?? '#3A3E44', ''], [o.mid ?? '#6A6F76', ''], [o.hi ?? '#A3A8AE', '']];
  const q = step * 0.62;
  for (let y = 0; y < h; y += step) for (let x = 0; x < w; x += step) {
    const u = x / w, v = y / h;
    const cloud = 0.6 * noise2(u * 3.2, v * 3.2, 1) + 0.4 * noise2(u * 7, v * 7, 2);
    const vig = 1 - 0.9 * Math.pow(Math.hypot(u - 0.48, v - 0.45) / 0.72, 2.2);
    const lum = Math.max(0, Math.min(1, (0.25 + 0.65 * cloud) * vig + (rnd() - 0.5) * 0.35));
    if (rnd() > 0.25 + lum * 0.75) continue;
    const t = lum > 0.62 ? 2 : lum > 0.36 ? 1 : 0;
    tones[t][1] += `M${f2(x + rnd() * step * 0.35)} ${f2(y + rnd() * step * 0.35)}h${f2(q)}v${f2(q)}h${f2(-q)}Z`;
  }
  return tones.filter(([, d]) => d).map(([fill, d]) => ({ type: 'path', id: nid('p'), x: 0, y: 0, width: w, height: h, viewBox: [0, 0, w, h], geometry: d, fill }));
}
const DARK = '#08090B';

// the frame: sky, the dark jet, the arc that tracks it, contrails, and in the hero the HUD readouts
function scene(size, st = 'idle', o = {}) {
  const px = Math.max(1, size / 160), hud = st === 'asks' ? C.sig : '#F2F2EE';
  const step = o.step ?? Math.max(2.2, size / 110);
  const sweep = st === 'working' ? 140 : st === 'done' ? 360 : 360 - GAP;
  const kids = [...sky(size, size, step, st === 'sleep' ? { lo: '#1E2125', mid: '#2C3035', hi: '#3A3E44' } : {})];
  if (st !== 'sleep') {
    kids.push(strokeP(size, trailD(70, -14), hud, px * 0.9), strokeP(size, line([4, 108], [96, -20]), '#D6D7D3', px * 0.7));
  }
  kids.push(fillP(size, jetD(), st === 'sleep' ? '#15171A' : DARK));
  if (st !== 'sleep') {
    kids.push(strokeP(size, sweep === 360 ? `${arc(50, 50, 30, 0, 180)}${arc(50, 50, 30, 180, 180).replace('M', 'L')}` : arc(50, 50, 30, GAP_END, sweep), hud, px * 1.3));
    if (sweep < 360) kids.push(strokeP(size, radial(50, 50, 30, 25, GAP_END + sweep), hud, px * 1.3));
  }
  if (st === 'asks') kids.push(strokeP(size, 'M50 24L76 50L50 76L24 50Z', C.sig, px * 1.2));
  if (o.hud) {
    const tx = (x, y, s, sz = 0.045, c = hud) => at(x * size, y * size, T(s, { size: size * sz, color: c, font: MONO }));
    const tick = (x, y, hgt) => `M${x} ${y}V${y + hgt}`;
    kids.push(
      strokeP(size, [30, 40, 50, 60, 70].map((x) => tick(x, 9, 3)).join('') + 'M26 17L28.5 12.5L31 17Z M69 17L71.5 12.5L74 17Z M62 24H67 M64.5 21.5V26.5', hud, px),
      tx(0.27, 0.025, '5'), tx(0.375, 0.025, '26'), tx(0.475, 0.025, '27'), tx(0.575, 0.025, '28'), tx(0.68, 0.18, '248', 0.035),
      tx(0.05, 0.27, '283', 0.07), tx(0.86, 0.27, '512', 0.07), tx(0.9, 0.34, '513', 0.03),
      tx(0.66, 0.36, '40', 0.05), tx(0.04, 0.45, '5.26', 0.035), tx(0.45, 0.83, '126', 0.04), tx(0.6, 0.83, '125', 0.04),
      tx(0.88, 0.13, '9', 0.04),
    );
  }
  return F({ layout: 'none', width: size, height: size, clip: true, fill: DARK, cornerRadius: o.r ?? 0 }, kids);
}

function mascotBody() {
  const hero = panel({ padding: [36, 40], gap: 18, width: 600, height: 600 }, [scene(480, 'idle', { hud: true, step: 3.2 }), cap('main mark · the jet, in its footage')]);
  const lockup = panel({ width: 540, height: 230 }, [
    H({ gap: 22, alignItems: 'center' }, [scene(110, 'idle', { r: 4 }), F({ gap: 4 }, [tape(250, C.t4, 25), T('UPGRADE', { font: COND, size: 64, weight: 600, ls: 4 })])]),
    cap('lockup · heading tape over the wordmark'),
  ]);
  const icons = panel({ width: 540, height: 250 }, [H({ gap: 26, alignItems: 'end' }, [
    F({ gap: 8, alignItems: 'center' }, [scene(144, 'idle', { r: 32 }), cap('app icon')]),
    F({ gap: 8, alignItems: 'center' }, [scene(72, 'idle', { r: 16 }), cap('72')]),
    F({ gap: 8, alignItems: 'center' }, [scene(40, 'idle', { r: 8, step: 2 }), cap('40')]),
    F({ gap: 8, alignItems: 'center' }, [jet(20, 'idle', { ring: false, trail: false }), cap('20 · jet only')]),
  ])]);
  const states = panel({}, [
    H({ gap: 20 }, [['idle', 'idle'], ['working', 'working'], ['asks', 'asks you'], ['done', 'done'], ['sleep', 'asleep']].map(([s, c]) =>
      F({ gap: 8, alignItems: 'center' }, [F({ padding: [8, 8], fill: C.s1, stroke: s === 'asks' ? C.sig : C.b2, strokeWidth: 1 }, [scene(130, s)]), cap(c, s === 'asks' ? C.sig : C.t3)]))),
    T('Idle: the jet dark against the grain, inside the open arc. Working: the arc unwinds as the job runs. Asks you: the lines lock orange around the jet. Done: the arc closes into a full ring. Asleep: the sky goes dark, no lines.', { font: SANS, size: 12, color: C.gold, w: 880, lh: 1.45 }),
  ]);
  return F({ gap: 20 }, [H({ gap: 20, alignItems: 'start' }, [hero, F({ gap: 20 }, [lockup, icons])]), states]);
}

// texture layers for B13 cards (340x150); text sits in the left 230px
const TEX = {
  A: () => F({ layout: 'none', width: 340, height: 150 }, [at(0, 118, tape(340, C.tex, 24))]),
  B: () => at(170, -20, F({ layout: 'none', width: 230, height: 230 }, [strokeP(230, arc(50, 50, 36, GAP_END, 360 - GAP), C.tex, 3), strokeP(230, trailD(70), C.tex, 1.5), fillP(230, jetD(), C.tex)])),
  C: () => grain(340, 150, 7, C.tex, (x, y) => Math.max(0, x * 0.9 + y * 0.6 - 0.75)),
  D: () => at(226, 10, F({ layout: 'none', width: 130, height: 130 }, [
    strokeP(130, arc(50, 50, 36, GAP_END, 360 - GAP), C.texHot, 2), strokeP(130, 'M50 22L78 50L50 78L22 50Z', '#5A2512', 1.4), fillP(130, jetD(), '#5A2512'), strokeP(130, trailD(60), C.texHot, 1),
  ])),
};

const board = (pen, id) => pen.children.find((c) => c.id === id);
function setHeader(b, title, sub, news) {
  const head = b.children[0], k = head.children;
  k[1].content = title; k[2].content = sub;
  const box = k[3], proto = box.children[1];
  box.children = [box.children[0], ...news.map((s) => ({ ...proto, id: nid('t'), content: `· ${s}` }))];
}

const [inp, out] = process.argv.slice(2);
const pen = JSON.parse(fs.readFileSync(inp, 'utf8'));

const b12 = board(pen, 'B12');
b12.name = 'board/12 · mascot';
setHeader(b12, 'MASCOT_  THE JET',
  'The jet from the reference footage, kept in its footage: a grey, grainy sky drawn in dots, the jet dark against it, and thin bright HUD lines on top: the arc that tracks it, the contrails, the heading tape and the readouts. The direction for the rest is sky and space.',
  ['Clean vector logo dropped. The mark keeps the footage look: dotted film grain with cloud blotches and a vignette, the jet as a dark shape against it.', 'HUD on top in thin bright lines: tracking arc, contrails, heading tape with carets, readouts.', 'States: the arc unwinds while working, the lines lock orange when something waits, the ring closes when done, the sky goes dark asleep.']);
b12.children[1] = mascotBody();

const b13 = board(pen, 'B13');
setHeader(b13, 'TEXTURE_  THE HUD INSIDE CARDS',
  'HUD fragments sit behind content as an inner layer, two steps above the card fill so text never fights them. Four uses, then the rules that keep it from turning into wallpaper.',
  ['Textures redrawn from the sky: a heading tape, the jet in its arc cropped off the edge, film grain, and the orange lock.']);
const cells = b13.children[1].children[0].children;
const notes = [
  ['A · HEADING TAPE', 'A heading tape runs along the bottom edge, under the rows. Summary cards and empty states.', 'A'],
  ['B · JET IN ARC', 'The jet in its open arc, trail and all, cropped off the right edge of the empty Agents card.', 'B'],
  ['C · FILM GRAIN', 'Gun-camera grain thickening into one corner. Behind dense rows; no shape to read.', 'C'],
  ['D · LOCK', 'Only the card that needs you: the jet in its asks state, locked inside the diamond.', 'D'],
];
cells.forEach((cell, i) => {
  const [label, card, note] = cell.children;
  label.content = notes[i][0]; note.content = notes[i][1];
  card.children[0] = TEX[notes[i][2]]();
});

fs.writeFileSync(out, JSON.stringify(pen));
