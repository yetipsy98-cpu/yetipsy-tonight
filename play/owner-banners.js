// Shared Owner image uploader for the member console and POS admin.
export const BANNER_BUCKET='yetipsy-home-banners';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function validateBannerFile(file){
 if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type))throw Error('请选择 JPG、PNG 或 WebP 图片');
 if(file.size>5*1024*1024)throw Error('图片不能超过 5 MB');
}
export async function prepareBannerImage(file){
 validateBannerFile(file);const image=await createImageBitmap(file);
 try{const scale=Math.min(1,1600/Math.max(image.width,image.height));const canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(image.width*scale));canvas.height=Math.max(1,Math.round(image.height*scale));
 const ctx=canvas.getContext('2d');ctx.fillStyle='#111614';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(image,0,0,canvas.width,canvas.height);
 const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',.9));if(!blob)throw Error('图片处理失败，请换一张图片');return blob;
 }finally{image.close();}
}
export function createBannerManager({db,root,notify,onPublished=async()=>{}}){
 const q=s=>root.querySelector(s);let rows=[],editing=null,imagePath=null,previewURL=null,saving=false;
 root.innerHTML='<div class="banner-manager"><h3>轮播广告</h3><form class="banner-form"><label>广告名称<input name="title" maxlength="80" required placeholder="例如：本周新品"></label><label>广告图片（16:9 · 最大 5 MB）<input name="image" type="file" accept="image/jpeg,image/png,image/webp"></label><img class="banner-upload-preview hide" alt="广告预览"><label>排序<input name="sort" type="number" min="0" max="999" value="10" required></label><label class="check-row"><input name="enabled" type="checkbox" checked> 上架到首页</label><div class="banner-form-actions"><button class="button button-primary" type="submit">上传并保存</button><button class="button button-outline" type="button" data-banner-new>新增广告</button></div><p class="banner-save-status" role="status" aria-live="polite"></p></form><div class="banner-manager-list"></div></div>';
 const field=name=>q('[name="'+name+'"]'),status=q('.banner-save-status'),image=q('.banner-upload-preview');
 const url=path=>db.storage.from(BANNER_BUCKET).getPublicUrl(path).data.publicUrl;
 function clearPreview(){if(previewURL){URL.revokeObjectURL(previewURL);previewURL=null;}}
 function reset(){editing=null;imagePath=null;q('form').reset();clearPreview();image.classList.add('hide');q('button[type="submit"]').textContent='上传并保存';status.textContent='';}
 function render(){const list=q('.banner-manager-list');list.innerHTML=rows.length?rows.map(r=>'<div class="banner-manager-row"><img src="'+esc(url(r.image_path))+'" alt="'+esc(r.title)+'" loading="lazy"><div><strong>'+esc(r.title)+'</strong><small>'+ (r.enabled?'已上架':'已下架')+' · 排序 '+Number(r.sort_order)+'</small></div><button type="button" class="button button-outline" data-banner-edit="'+esc(r.id)+'">编辑</button></div>').join(''):'<p class="soft-text">暂无广告，上传第一张后即可在首页显示。</p>';}
 async function load(){const res=await db.rpc('yt_owner_banner_list');if(res.error)throw Error(res.error.message);rows=res.data||[];render();}
 q('[data-banner-new]').onclick=()=>{if(!saving)reset();};
 field('image').onchange=()=>{try{const file=field('image').files[0];if(!file)return;validateBannerFile(file);clearPreview();previewURL=URL.createObjectURL(file);image.src=previewURL;image.classList.remove('hide');imagePath=null;}catch(e){field('image').value='';notify(e.message,true);}};
 q('.banner-manager-list').onclick=e=>{const b=e.target.closest('[data-banner-edit]');if(!b||saving)return;const r=rows.find(x=>x.id===b.dataset.bannerEdit);if(!r)return;reset();editing=r.id;imagePath=r.image_path;field('title').value=r.title;field('sort').value=r.sort_order;field('enabled').checked=r.enabled;image.src=url(r.image_path);image.classList.remove('hide');q('button[type="submit"]').textContent='保存广告';field('title').focus();};
 q('form').onsubmit=async e=>{e.preventDefault();if(saving)return;const title=field('title').value.trim(),sort=Number(field('sort').value),enabled=field('enabled').checked,file=field('image').files[0];
 try{if(!title||title.length>80||!Number.isInteger(sort)||sort<0||sort>999)throw Error('请填写广告名称和有效排序');if(!imagePath&&!file)throw Error('请先选择广告图片');
 saving=true;root.querySelectorAll('input,button').forEach(el=>el.disabled=true);
 if(!imagePath){status.textContent='正在上传图片…';const blob=await prepareBannerImage(file),path='ads/'+crypto.randomUUID()+'.jpg';const res=await db.storage.from(BANNER_BUCKET).upload(path,blob,{contentType:'image/jpeg',cacheControl:'3600',upsert:false});if(res.error)throw Error(res.error.message);imagePath=path;}
 status.textContent='正在保存广告…';const res=await db.rpc('yt_owner_banner_save',{p_id:editing,p_title:title,p_image_path:imagePath,p_sort:sort,p_enabled:enabled});if(res.error)throw Error(res.error.message);
 editing=res.data;await load();await onPublished();status.textContent=enabled?'已保存，客户端首页已更新':'已保存，广告已下架';notify(status.textContent);
 }catch(err){status.textContent=err.message;notify(err.message,true);}finally{saving=false;root.querySelectorAll('input,button').forEach(el=>el.disabled=false);}
 };
 return {load};
}
