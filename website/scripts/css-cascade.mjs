// Reads stylesheets in the order a page loads them, to check that an override never loads before
// the rule it overrides. The build splits stylesheets by which pages share them, so the order in the
// built page is not the order of the <link> tags in the template.
const clean=text=>text.replace(/\/\*[\s\S]*?\*\//g,'');
const tidy=text=>text.trim().replace(/\s+/g,' ').replace(/\s*([>+~,])\s*/g,'$1');
// Split on a separator that is not inside parentheses or quotes (data URLs carry both ; and ,).
function split(text,separator){
  const parts=[];let depth=0,quote='',start=0;
  for(let i=0;i<text.length;i++){
    const character=text[i];
    if(quote){if(character===quote)quote='';}
    else if(character==='"'||character==="'")quote=character;
    else if(character==='(')depth++;
    else if(character===')')depth--;
    else if(character===separator&&depth===0){parts.push(text.slice(start,i));start=i+1;}
  }
  parts.push(text.slice(start));return parts;
}
function closing(text,open){
  let depth=0,quote='';
  for(let i=open;i<text.length;i++){
    const character=text[i];
    if(quote){if(character===quote)quote='';}
    else if(character==='"'||character==="'")quote=character;
    else if(character==='{')depth++;
    else if(character==='}'&&--depth===0)return i;
  }
  throw new Error('Unbalanced braces in stylesheet');
}

// Every style rule as {condition, selector, declarations}, one per selector of a selector list.
// `condition` is the enclosing @media / @container / @supports prelude, or null for a rule that
// always applies; `declarations` maps each property to its value as written.
export function cssStyles(source,condition=null){
  const text=clean(source),rules=[];
  for(let at=0;at<text.length;){
    const open=text.indexOf('{',at);
    if(open<0)break;
    // A statement such as `@import …;` may sit in front of the next rule: it is not part of its selector.
    const prelude=text.slice(at,open).split(';').at(-1).trim(),close=closing(text,open),body=text.slice(open+1,close);
    at=close+1;
    if(/^@(media|container|supports)\b/.test(prelude))rules.push(...cssStyles(body,tidy(condition?`${condition} and ${prelude}`:prelude)));
    else if(!prelude.startsWith('@')){
      const declarations={};
      for(const declaration of split(body,';')){
        const colon=declaration.indexOf(':');
        if(colon>0)declarations[declaration.slice(0,colon).trim().toLowerCase()]=declaration.slice(colon+1).trim();
      }
      for(const selector of split(prelude,','))rules.push({condition,selector:tidy(selector),declarations});
    }
  }
  return rules;
}
// The same rules with property names only.
export const cssRules=source=>cssStyles(source).map(({condition,selector,declarations})=>({condition,selector,properties:Object.keys(declarations)}));

// `sheets` is [{name, css}] in load order. Returns one line per (selector, property) whose conditional
// override loads before an unconditional declaration of the same selector and property.
export function cascadeConflicts(sheets){
  const first=new Map(),conflicts=new Map();
  for(const sheet of sheets)for(const rule of cssRules(sheet.css))for(const property of rule.properties){
    const key=`${rule.selector} { ${property} }`;
    if(rule.condition){if(!first.has(key))first.set(key,{sheet:sheet.name,condition:rule.condition});}
    else if(first.has(key)&&!conflicts.has(key)){
      const override=first.get(key);
      conflicts.set(key,`${key}: the ${override.condition} override in ${override.sheet} loads before the base rule in ${sheet.name}`);
    }
  }
  return [...conflicts.values()];
}
