-- Reservation-date validity is checked when redeeming/creating an Amba order.
-- An existing order may settle later or have its accounting day corrected.
-- Keep pass status and payment-method checks; never extend FreeFlow access here.
create or replace function private.yt_ambassador_pos_payment_method()
returns trigger language plpgsql security definer set search_path='' as $$
declare s public.yt_ambassador_pos_sales%rowtype; v public.yt_ambassador_passes%rowtype;
begin
 if new.source<>'future_pos' or new.payment_status<>'paid' or old.payment_status='paid' then return new;end if;
 select * into s from public.yt_ambassador_pos_sales where order_id=new.id;
 if s.order_id is null then
  if coalesce(new.payment_method,'') like 'AB_%' then raise exception 'invalid_payment_method';end if;
  return new;
 end if;
 select * into v from public.yt_ambassador_passes where id=s.pass_id and status='issued';
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 if new.payment_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') then raise exception 'invalid_payment_method';end if;
 new.payment_method:='AB_'||case new.payment_method when 'duitnow' then 'DuitNow' when 'cash' then 'Cash'
  when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end;
 return new;
end $$;
