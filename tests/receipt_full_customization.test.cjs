const assert=require('node:assert/strict'),fs=require('node:fs');
const read=p=>fs.readFileSync(p,'utf8');
const layout=read('play/pos/receipt-layout.js'),editor=read('play/pos/receipt-layout-editor.js'),pos=read('play/pos/pos.js'),sql=read('sql/20261020_receipt_freeform_layout.sql'),html=read('play/admin/pos/index.html');
assert.match(layout,/payment_method/);assert.match(layout,/type:'text'/);assert.match(layout,/type:'divider'/);assert.match(layout,/gridTemplateColumns='repeat\(2/);
assert.match(editor,/自定义文字/);assert.match(editor,/分隔线/);assert.match(editor,/data-prop="width"/);assert.match(editor,/data-prop="align"/);assert.match(editor,/setPointerCapture/);
assert.match(pos,/data-receipt-field=/);assert.match(pos,/field\('payment_method'/);assert.match(pos,/data\.receipt_settings\|\|\{\}/);
assert.match(sql,/length\(p_layout::text\)>30000/);assert.match(sql,/jsonb_array_length\(elements\)>32/);assert.match(sql,/length\(el->>'text'\)>240/);assert.match(sql,/private\.yt_work_owner\(\)/);assert.match(sql,/revoke all on function public\.yt_receipt_layout_save/);
assert.match(html,/receipt-freeform-v1/);
console.log('PASS: fully customizable receipt editor contracts and bounded owner-only layout saving.');
