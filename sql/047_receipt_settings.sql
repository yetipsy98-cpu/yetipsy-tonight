-- Owner-managed receipt layout shared by every workbench device.
create table public.yt_receipt_settings(
 id smallint primary key default 1 check(id=1),
 business_name text not null default 'YE·TIPSY' check(char_length(business_name) between 1 and 80),
 subtitle text not null default 'KLUANG · POINT OF SALE' check(char_length(subtitle)<=120),
 address_line text not null default '' check(char_length(address_line)<=240),
 contact_line text not null default '' check(char_length(contact_line)<=160),
 footer_text text not null default 'Thank you for visiting Yetipsy.' check(char_length(footer_text)<=300),
 paper_width_mm integer not null default 80 check(paper_width_mm in (58,80)),
 receipt_language text not null default 'bilingual' check(receipt_language in ('zh','en','bilingual')),
 show_table boolean not null default true,
 show_staff boolean not null default true,
 show_notes boolean not null default true,
 show_discounts boolean not null default true,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null
);
insert into public.yt_receipt_settings(id) values(1);
alter table public.yt_receipt_settings enable row level security;
revoke all on public.yt_receipt_settings from public,anon,authenticated;

create function private.yt_receipt_settings_get() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select to_jsonb(s)-'id'-'updated_by' into result from public.yt_receipt_settings s where id=1;
 return result;
end;$$;

create function private.yt_receipt_settings_save(p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 business text:=btrim(coalesce(p_data->>'business_name',''));
 subtitle_value text:=btrim(coalesce(p_data->>'subtitle',''));
 address_value text:=btrim(coalesce(p_data->>'address_line',''));
 contact_value text:=btrim(coalesce(p_data->>'contact_line',''));
 footer_value text:=btrim(coalesce(p_data->>'footer_text',''));
 width_value integer;
 language_value text:=coalesce(p_data->>'receipt_language','bilingual');
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 begin width_value:=(p_data->>'paper_width_mm')::integer;exception when others then raise exception 'invalid_receipt_width';end;
 if char_length(business) not between 1 and 80 or char_length(subtitle_value)>120
  or char_length(address_value)>240 or char_length(contact_value)>160 or char_length(footer_value)>300
  then raise exception 'invalid_receipt_text';end if;
 if width_value is null or width_value not in (58,80) then raise exception 'invalid_receipt_width';end if;
 if language_value not in ('zh','en','bilingual') then raise exception 'invalid_receipt_language';end if;
 update public.yt_receipt_settings set
  business_name=business,subtitle=subtitle_value,address_line=address_value,contact_line=contact_value,footer_text=footer_value,
  paper_width_mm=width_value,receipt_language=language_value,
  show_table=coalesce((p_data->>'show_table')::boolean,true),
  show_staff=coalesce((p_data->>'show_staff')::boolean,true),
  show_notes=coalesce((p_data->>'show_notes')::boolean,true),
  show_discounts=coalesce((p_data->>'show_discounts')::boolean,true),
  updated_at=clock_timestamp(),updated_by=auth.uid()
 where id=1;
 insert into public.audit_logs(actor_id,action,entity_type,metadata)
 values(auth.uid(),'pos.receipt_settings','receipt_settings',jsonb_build_object('settings',p_data));
 return private.yt_receipt_settings_get();
end;$$;

create function public.yt_receipt_settings_get() returns jsonb
language sql security invoker set search_path='' as $$select private.yt_receipt_settings_get();$$;
create function public.yt_receipt_settings_save(p_data jsonb) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_receipt_settings_save(p_data);$$;
revoke all on function private.yt_receipt_settings_get(),private.yt_receipt_settings_save(jsonb),public.yt_receipt_settings_get(),public.yt_receipt_settings_save(jsonb) from public,anon;
grant execute on function private.yt_receipt_settings_get(),private.yt_receipt_settings_save(jsonb),public.yt_receipt_settings_get(),public.yt_receipt_settings_save(jsonb) to authenticated;

-- Add the current receipt settings to the existing atomic bill payload.
create or replace function private.yt_pos_receipt(p_order uuid)
 returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 return jsonb_build_object(
  'id',v.id,'order_no',v.order_no,'table_label',v.table_label,
  'notes',v.notes,'status',v.status,'payment_status',v.payment_status,
  'payment_method',v.payment_method,'paid_at',v.paid_at,'paid_by',v.paid_by,
  'created_at',v.created_at,'updated_at',v.updated_at,
  'discount_total_rm',coalesce((select sum(u.reward_discount_rm)
    from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id
    where i.order_id=v.id and i.quantity>0 and not u.retired),0),
  'gross_total_rm',coalesce((select sum(i.quantity*i.unit_price_rm)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),0),
  'amount_rm',v.amount_rm,
  'created_by',(select a.username from public.work_accounts a where a.auth_user_id=v.created_by),
  'items',coalesce((select jsonb_agg(jsonb_build_object(
    'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
    'line_total_rm',i.quantity*i.unit_price_rm-coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0),
    'discount_rm',coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0)) order by i.item_name,i.id)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),'[]'::jsonb),
  'document_type',case when v.payment_status='paid' then 'PAYMENT RECEIPT' else 'UNPAID BILL - NOT A RECEIPT' end,
  'disclaimer','Internal Yetipsy order record. Foodcourt payment method is recorded by cashier; not a tax invoice.',
  'receipt_settings',private.yt_receipt_settings_get()
 );
end;$$;

revoke all on function private.yt_pos_receipt(uuid) from public,anon;
grant execute on function private.yt_pos_receipt(uuid) to authenticated;
