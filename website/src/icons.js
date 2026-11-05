// Small UI symbols only; the 3D scene and product copy live elsewhere.
export function icon(name, cls = '') {
  const shapes = {
    arrow: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
    play: '<path d="m9 5 11 7-11 7Z" fill="currentColor" stroke="none"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    close: '<path d="m6 6 12 12M6 18 18 6"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    chevron: '<path d="m7 10 5 5 5-5"/>',
    pause: '<path d="M9 5v14M15 5v14" stroke-width="3"/>',
    cut: '<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="m8 8 12 12M8 16 20 4"/>',
    picture: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m3 16 6-6 5 5 3-3 4 4"/><circle cx="16" cy="8" r="1"/>',
    words: '<path d="M4 5h16M12 5v15M8 20h8"/>',
    sound: '<path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4"/>',
    ai: '<path d="m12 3 3 6 6 3-6 3-3 6-3-6-6-3 6-3Z"/>',
    mac: '<rect x="3" y="3" width="18" height="13" rx="2"/><path d="M9 21h6M12 16v5"/>',
    windows: '<path d="M3 4h8v7H3ZM14 4h7v7h-7ZM3 14h8v7H3ZM14 14h7v7h-7Z"/>',
    globe: '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
  };
  return `<svg class="icon ${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${shapes[name] || shapes.arrow}</svg>`;
}
