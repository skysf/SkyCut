// Timeline ribbons made from different moments of each video, preserving frame geometry.
export function filmstrip(kind,index=0) {
  const total=12;
  const start=kind==='create'?index*4:0;
  const count=kind==='create'?4:total;
  return `<div class="show-filmstrip" aria-hidden="true">${Array.from({length:count},(_,i)=>`<svg class="show-film-cell" viewBox="${(start+i)*160} 0 160 90" preserveAspectRatio="xMidYMid slice"><image href="/media/demo-${kind}-strip.jpg" width="${total*160}" height="90"/></svg>`).join('')}</div>`;
}
