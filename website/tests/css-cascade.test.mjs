// Stylesheets must not depend on a load order the build does not keep.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {cssRules,cascadeConflicts} from '../scripts/css-cascade.mjs';
const sheet=async name=>({name:`${name}.css`,css:await readFile(new URL(`../src/styles/${name}.css`,import.meta.url),'utf8')});
// Styles of one kind of page; responsive.css and base.css are linked by every page.
const PAGE_SHEETS=['home','showcases','pricing','guides'];

test('responsive.css only adjusts what base.css styles, so it may load before a page\'s own stylesheet',async()=>{
  const shared=new Set(cssRules((await sheet('responsive')).css).map(rule=>rule.selector));
  for(const name of PAGE_SHEETS){
    const own=new Set(cssRules((await sheet(name)).css).map(rule=>rule.selector));
    const both=[...shared].filter(selector=>own.has(selector));
    assert.deepEqual(both,[],`${name}.css styles these too; their tablet and phone rules belong at the end of ${name}.css, not in responsive.css`);
  }
});

test('whichever chunk the build puts first, no override comes before its base rule',async()=>{
  // The build groups stylesheets by which pages share them: the shared pair first, then a page's own.
  for(const order of [['base','home','responsive','showcases','pricing'],['base','responsive','home','showcases','pricing'],['base','responsive','guides']]){
    assert.deepEqual(cascadeConflicts(await Promise.all(order.map(sheet))),[],order.join(' > '));
  }
});

test('the reader finds an override that loads first, through commas, nesting and data URLs',()=>{
  const base={name:'page.css',css:`/* note */ .hero,.deck > i {display:grid;background:url("data:image/svg+xml;charset=utf8,%3Csvg%3E{}'") no-repeat;}`};
  const narrow={name:'shared.css',css:'@media(max-width:600px){ .hero {display:block;} @supports (gap:1px){ .deck>i{background:none} } } @font-face{font-family:x;src:url(a.woff2)}'};
  assert.deepEqual(cssRules(narrow.css),[
    {condition:'@media(max-width:600px)',selector:'.hero',properties:['display']},
    {condition:'@media(max-width:600px) and @supports (gap:1px)',selector:'.deck>i',properties:['background']}
  ]);
  assert.deepEqual(cascadeConflicts([base,narrow]),[]);
  // A statement before the first rule does not swallow it.
  assert.deepEqual(cssRules("@import 'font';\n:root {--paper:#fff;}"),[{condition:null,selector:':root',properties:['--paper']}]);
  const conflicts=cascadeConflicts([narrow,base]);
  assert.equal(conflicts.length,2);
  assert.match(conflicts[0],/^\.hero \{ display \}: the @media\(max-width:600px\) override in shared\.css loads before the base rule in page\.css$/);
});
