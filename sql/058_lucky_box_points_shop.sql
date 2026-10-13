-- Redeemable vouchers backed by the original reward wallet and POS checkout.
-- Only fixed-value RM2/RM5 have verifiable costs. Product rewards stay inactive
-- until the Owner validates each item's actual cost and POS fulfillment recipe.
do $$
declare def record;v_reward uuid;
begin
 for def in select * from (values
  ('Yetipsy Lucky Box · RM2 Voucher','voucher',200,true,'下次消费购买至少一杯合资格饮品可抵扣 RM2。每单最多兑换一份，不与其他折扣叠加。',2::numeric,10),
  ('Yetipsy Lucky Box · 奶茶指定升级','custom',300,false,'待确认具体升级内容与制作成本（最高 RM3）；确认后才开放兑换。',null::numeric,20),
  ('Yetipsy Lucky Box · RM5 Voucher','voucher',500,true,'下次消费购买至少一杯合资格饮品可抵扣 RM5。每单最多兑换一份，不与其他折扣叠加。',5::numeric,30),
  ('Yetipsy Lucky Box · Rainbow Shot','custom',700,false,'待核实每份 Rainbow Shot 实际成本不超过 RM7；确认后才开放兑换。',null::numeric,40),
  ('Yetipsy Lucky Box · 指定经典鸡尾酒','custom',1000,false,'待选择并核实实际成本不超过 RM10 的指定鸡尾酒；确认后才开放兑换。',null::numeric,50),
  ('Yetipsy Lucky Box · 指定微醺特调','custom',1500,false,'待选择并核实实际成本不超过 RM15 的指定微醺特调；确认后才开放兑换。',null::numeric,60)
 ) d(name,category,cost,is_live,description,face_rm,sort_key)
 loop
   select id into v_reward from public.rewards where name=def.name order by created_at limit 1;
   if v_reward is null then
     insert into public.rewards(name,description,redeem_rules,active,validity_days,next_day_only,category)
     values(def.name,def.description,'限定至下次到店使用，至少购买一杯合资格付费饮品；不得叠加其他优惠。',def.is_live,30,true,def.category)
     returning id into v_reward;
   end if;
   if not exists(select 1 from public.yt_pos_reward_rules where reward_id=v_reward) then
     if def.is_live then
       insert into public.yt_pos_reward_rules(reward_id,mode,discount_type,discount_value,min_paid_drinks,min_spend_rm)
       values(v_reward,'any_drink','fixed',def.face_rm,1,0);
     else
       insert into public.yt_pos_reward_rules(reward_id,mode,discount_type,discount_value,min_paid_drinks,min_spend_rm)
       values(v_reward,'disabled','free',0,1,0);
     end if;
   end if;
   if not exists(select 1 from public.yt_point_shop_items where reward_id=v_reward) then
     insert into public.yt_point_shop_items(reward_id,points_cost,active,per_member_limit,sort_order,description)
       values(v_reward,def.cost,def.is_live,null,def.sort_key,def.description);
   end if;
 end loop;
end $$;
