// Display-only estimate. Submission keeps using the authorised, server-priced RPC.
export function adjustmentPreview(gross,{kind='discount',type='rm',value='',focTotal=0}={}){
 const cents=n=>Math.round((Number(n)+Number.EPSILON)*100),base=cents(gross);
 const amount=Number(value);let discount=0,message='';
 if(kind==='foc'){discount=cents(focTotal);if(!discount)message='请选择要免单的商品。';}
 else if(value===''||!Number.isFinite(amount)||amount<=0)message='请填写折扣金额或百分比。';
 else if(type==='percent'){if(amount>=100)message='百分比需小于 100%。';else discount=Math.round(base*amount/100);}
 else if(type==='rm')discount=cents(amount);else message='请选择折扣类型。';
 if(!message&&(discount<=0||base-discount<1))message='优惠后至少保留 RM0.01。';
 return {gross:base/100,discount:Math.max(0,discount)/100,net:(base-discount)/100,valid:!message,message};
}
