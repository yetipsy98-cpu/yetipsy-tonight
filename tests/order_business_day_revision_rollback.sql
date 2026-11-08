-- Run in BEGIN/ROLLBACK. No real ledger, order or closing changes survive.
do $$
declare actor uuid;cashier uuid;product uuid;o uuid;item uuid;req uuid;payload jsonb; r jsonb;before_updated timestamptz;paid_time timestamptz:=clock_timestamp();
 today date:=private.yt_business_day(clock_timestamp());old_day date;new_day date;newer_day date;closed_old uuid;closed_new uuid; base_old numeric;base_new numeric;base_today numeric;
begin
 old_day:=today-2;new_day:=(date_trunc('month',today)::date-interval '1 month'+interval '17 days')::date;newer_day:=new_day-1;
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into cashier from public.work_accounts where role='cashier' and active and not must_change_password limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 base_old:=(public.yt_owner_report_v8(old_day,old_day)#>>'{stats,range_amount}')::numeric;base_new:=(public.yt_owner_report_v8(new_day,new_day)#>>'{stats,range_amount}')::numeric;base_today:=(public.yt_owner_report_v8(today,today)#>>'{stats,range_amount}')::numeric;
 insert into public.yt_shop_products(title,price_rm,active,is_drink) values('rollback business day',20,true,true) returning id into product;
 insert into public.yt_member_orders(source,status,amount_rm,created_by,created_at) values('future_pos','fulfilled',20,actor,private.yt_business_start(old_day)+interval '2 hours') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback business day',1,20) returning id into item;
 update public.yt_member_orders set payment_status='paid',paid_at=paid_time,paid_by=actor,payment_method='cash' where id=o;
 if (select business_day from public.yt_pos_payment_entries where order_id=o and kind='sale')<>old_day then raise exception 'held_sale_used_receipt_day';end if;
 if (select received_at from public.yt_pos_payment_entries where order_id=o and kind='sale')<>paid_time then raise exception 'actual_receipt_time_changed';end if;
 if (public.yt_owner_report_v8(old_day,old_day)#>>'{stats,range_amount}')::numeric<>base_old+20 or (public.yt_owner_report_v8(today,today)#>>'{stats,range_amount}')::numeric<>base_today then raise exception 'held_sale_report_wrong';end if;
 -- Closed statements on both sides must be reopened, while snapshots survive.
 insert into public.yt_pos_day_closings(business_day,revision,state,request_id,opening_cash,cash_out,expected_cash,actual_cash,difference_rm,snapshot,closed_by)
 select old_day,coalesce(max(revision),0)+1,'closed',gen_random_uuid(),0,0,0,0,0,'{"marker":"old"}'::jsonb,actor from public.yt_pos_day_closings where business_day=old_day returning id into closed_old;
 insert into public.yt_pos_day_closings(business_day,revision,state,request_id,opening_cash,cash_out,expected_cash,actual_cash,difference_rm,snapshot,closed_by)
 select new_day,coalesce(max(revision),0)+1,'closed',gen_random_uuid(),0,0,0,0,0,'{"marker":"new"}'::jsonb,actor from public.yt_pos_day_closings where business_day=new_day returning id into closed_new;
 select updated_at into before_updated from public.yt_member_orders where id=o;
 payload:=jsonb_build_array(jsonb_build_object('item_id',item,'product_id',product,'quantity',2,'unit_price_rm',20));req:=gen_random_uuid();
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',cashier)::text,true);
 begin perform public.yt_pos_owner_revision_apply_v3(o,payload,'test dates',null,null,before_updated,req,false,false,null,new_day);raise exception 'cashier_changed_date';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 begin perform public.yt_pos_owner_revision_apply_v3(o,payload,'test dates',null,null,before_updated,req,false,false,null,today+1);raise exception 'future_day_allowed';exception when others then if sqlerrm<>'invalid_business_day' then raise;end if;end;
 r:=public.yt_pos_owner_revision_apply_v3(o,payload,'move business day',null,null,before_updated,req,false,false,'duitnow',new_day);
 if r->>'business_day'<>new_day::text or (r->>'balance_rm')::numeric<>20 then raise exception 'revision_result_wrong';end if;
 if exists(select 1 from public.yt_pos_payment_entries where order_id=o and (business_day<>new_day or received_at<>paid_time or amount_rm<>20)) then raise exception 'sale_not_moved_intact';end if;
 if (public.yt_owner_report_v8(old_day,old_day)#>>'{stats,range_amount}')::numeric<>base_old or (public.yt_owner_report_v8(new_day,new_day)#>>'{stats,range_amount}')::numeric<>base_new+20 then raise exception 'moved_day_report_wrong';end if;
 if (select method from public.yt_pos_payment_entries where order_id=o and kind='sale')<>'duitnow' then raise exception 'payment_method_regression';end if;
 if (select state from public.yt_pos_day_closings where id=closed_old)<>'reopened' or (select state from public.yt_pos_day_closings where id=closed_new)<>'reopened' then raise exception 'closing_not_reopened';end if;
 if (select snapshot->>'marker' from public.yt_pos_day_closings where id=closed_old)<>'old' then raise exception 'snapshot_overwritten';end if;
 r:=public.yt_pos_owner_revision_apply_v3(o,payload,'move business day',null,null,before_updated,req,false,false,'duitnow',new_day);
 if has_function_privilege('anon','public.yt_pos_owner_revision_apply_v3(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text,date)','execute') then raise exception 'anonymous_date_edit_access';end if;
 if not (r->>'retried')::boolean or (select count(*) from public.yt_pos_order_revisions where order_id=o)<>1 then raise exception 'revision_retry_duplicate';end if;
 begin perform public.yt_pos_owner_revision_apply_v3(o,payload,'move business day',null,null,before_updated,req,false,false,'duitnow',newer_day);raise exception 'date_retry_conflict_not_detected';exception when others then if sqlerrm<>'request_conflict' then raise;end if;end;
 perform public.yt_pos_adjustment_pay(o,20,'cash','actual topup',gen_random_uuid());
 if exists(select 1 from public.yt_pos_payment_entries where order_id=o and business_day<>new_day) then raise exception 'topup_wrong_day';end if;
 select updated_at into before_updated from public.yt_member_orders where id=o;
 payload:=jsonb_build_array(jsonb_build_object('item_id',item,'product_id',product,'quantity',1,'unit_price_rm',20));
 r:=public.yt_pos_owner_revision_apply_v3(o,payload,'move again refund',null,null,before_updated,gen_random_uuid(),false,false,null,newer_day);
 perform public.yt_pos_adjustment_pay(o,-20,'cash','actual refund',gen_random_uuid());
 if exists(select 1 from public.yt_pos_payment_entries where order_id=o and business_day<>newer_day) then raise exception 'refund_or_topup_not_moved';end if;
 if private.yt_pos_received(o)<>20 or (select count(*) from public.yt_pos_payment_entries where order_id=o)<>3 then raise exception 'money_or_entries_changed';end if;
 if private.yt_pos_owner_order_context(o)->>'business_day'<>newer_day::text then raise exception 'context_missing_day';end if;
 if (private.yt_pos_owner_order_context(o)#>>'{revisions,0,before_business_day}')<>new_day::text or (private.yt_pos_owner_order_context(o)#>>'{revisions,0,after_business_day}')<>newer_day::text then raise exception 'date_history_missing';end if;
end $$;
