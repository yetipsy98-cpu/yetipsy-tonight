const assert=require('node:assert/strict');
module.exports=function assertVersionedEntry(html,file){
 const scripts=[...html.matchAll(/<script\b[^>]*>/g)].map(m=>m[0]);
 const entries=scripts.filter(tag=>/\btype="module"/.test(tag)).map(tag=>tag.match(/\bsrc="([^"]+)"/)?.[1]).filter(Boolean);
 const entry=entries.find(src=>src.split('?')[0].split('/').at(-1)===file);
 assert(entry,'module entry exists: '+file);
 assert.match(entry,/\?v=[\w-]+(?:&[^"\s]+)?$/,'entry has a cache version: '+file);
 assert(html.includes('rel="modulepreload" href="'+entry+'"'),'preload matches the active '+file+' entry');
 return entry;
};
