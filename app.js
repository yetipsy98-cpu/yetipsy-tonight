const CFG=()=>window.YETIPSY_CONFIG||{};
const $=s=>document.querySelector(s); const $$=s=>[...document.querySelectorAll(s)];
function money(v){return 'RM '+Number(v||0).toFixed(2)}
function session(){try{return JSON.parse(localStorage.getItem('yt_session')||'null')}catch(e){return null}}
function saveSession(x){localStorage.setItem('yt_session',JSON.stringify(x))}
function logout(){localStorage.removeItem('yt_session');location.href='index.html'}
function toast(msg,type=''){let el=$('#notice');if(!el){el=document.createElement('div');el.id='notice';document.body.prepend(el)}el.className='notice '+(type||'');el.textContent=msg;setTimeout(()=>el.textContent='',5000)}
async function api(action,data={}){
  const url=CFG().GAS_URL; if(!url||url.includes('PASTE_')) throw new Error('请先在 config.js 填入 Apps Script Web App URL');
  const s=session(); const payload={action,...data}; if(s?.token) payload.session_token=s.token;
  const r=await fetch(url,{method:'POST',body:new URLSearchParams(payload)});
  const j=await r.json(); if(!j.ok) throw new Error(j.error||'API error'); return j.data;
}
async function login(role){
  try{const username=$('#username').value.trim(),password=$('#password').value; const d=await api('login',{role,username,password});saveSession(d);location.href=role+'.html'}catch(e){toast(e.message,'error')}
}
function requireRole(role){const s=session();const allowed=!!s&&(s.role===role||s.role==='admin');if(!allowed){location.href='index.html';return false}$('#who')&&($('#who').textContent=s.name||s.username);return true}
function fmtDate(x){if(!x)return '-';try{return new Date(x).toLocaleString()}catch(e){return x}}
function esc(v){return String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]))}
function jsq(v){return String(v??'').replace(/\\/g,'\\\\').replace(/'/g,"\\'")}
function setToday(id){const d=new Date();d.setMinutes(d.getMinutes()-d.getTimezoneOffset()); const el=$(id); if(el) el.value=d.toISOString().slice(0,10)}
