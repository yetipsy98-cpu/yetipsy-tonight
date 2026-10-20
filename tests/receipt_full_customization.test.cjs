const assert=require('node:assert/strict'),fs=require('node:fs');
const read=p=>fs.readFileSync(p,'utf8');
const cEditor=read('play/pos/receipt-settings.js'),layout=read('play/pos/receipt-layout.js'),editor=read('play/pos/receipt-layout-editor.js'),pos=read('play/pos/pos.js'),sql=read('sql/20261020_receipt_freeform_canvas.sql'),html=read('play/admin/pos/index.html');
assert.match(layout,/payment_method/);assert.match(layout,/position='absolute'/);assert.match(layout,/dataset\.elementKey=item\.key/);
assert.match(editor,/自定义文字/);assert.match(editor,/分隔线/);assert.match(editor,/data-prop="w"/);assert.match(editor,/data-prop="align"/);assert.match(editor,/contentEditable='true'/);assert.match(editor,/data-resize-handle/);assert.match(editor,/function movePointer/);assert.match(editor,/function openPreview/);assert.match(editor,/精细位置与尺寸/);
assert.match(pos,/const label=\(zh,en\)=>en/);assert.match(pos,/data-receipt-field=/);assert.match(pos,/field\('payment_method'/);assert.match(pos,/data\.receipt_settings\|\|\{\}/);
assert.match(sql,/length\(p_layout::text\)>30000/);assert.match(sql,/jsonb_array_length\(elements\)>32/);assert.match(sql,/length\(el->>'text'\)>240/);assert.match(sql,/canvas_height/);assert.match(sql,/coalesce\(el->>'x'/);assert.match(sql,/coalesce\(el->>'w'/);assert.match(sql,/private\.yt_work_owner\(\)/);assert.match(sql,/revoke all on function public\.yt_receipt_layout_save/);
assert.match(html,/receipt-english-easy-v4/);assert.match(cEditor,/English only/);
console.log('PASS: direct-manipulation receipt canvas contracts and bounded owner-only layout saving.');
