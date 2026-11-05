// Reuse the official Mac app icon pipeline. This creates browser sizes, not a second logo.
import {execFileSync} from 'node:child_process';
import {mkdtemp,readFile,writeFile,copyFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
const output=join(root,'website/public');
const temporary=await mkdtemp(join(tmpdir(),'skycut-favicons-'));
try {
  const iconset=join(temporary,'SkyCut.iconset');
  execFileSync('swift',['scripts/make-icon.swift',iconset],{cwd:root,stdio:'inherit'});
  await copyFile(join(iconset,'icon_16x16@2x.png'),join(output,'favicon-32.png'));
  await copyFile(join(iconset,'icon_32x32@2x.png'),join(output,'favicon-64.png'));
  execFileSync('/usr/bin/sips',['-z','180','180',join(iconset,'icon_128x128@2x.png'),'--out',join(output,'apple-touch-icon.png')],{stdio:'inherit'});
  const sizes=[16,32,64];
  const files=['icon_16x16.png','icon_16x16@2x.png','icon_32x32@2x.png'];
  const images=await Promise.all(files.map(file=>readFile(join(iconset,file))));
  const header=Buffer.alloc(6+16*images.length);
  header.writeUInt16LE(1,2);header.writeUInt16LE(images.length,4);
  let offset=header.length;
  images.forEach((bytes,index)=>{
    const entry=6+index*16;
    header[entry]=sizes[index];header[entry+1]=sizes[index];
    header.writeUInt16LE(1,entry+4);header.writeUInt16LE(32,entry+6);
    header.writeUInt32LE(bytes.length,entry+8);header.writeUInt32LE(offset,entry+12);
    offset+=bytes.length;
  });
  await writeFile(join(output,'favicon.ico'),Buffer.concat([header,...images]));
  console.log('Official SkyCut app icon exported for browser tabs and Apple touch icons');
} finally {
  await rm(temporary,{recursive:true,force:true});
}
