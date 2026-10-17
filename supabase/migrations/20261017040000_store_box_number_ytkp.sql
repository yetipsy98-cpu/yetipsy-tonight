alter table public.yt_store_boxes
  alter column box_number set default (
    'YTKP-' || lpad(nextval('public.yt_store_box_number_seq'::regclass)::text, 8, '0')
  );

update public.yt_store_boxes
set box_number = 'YTKP-' || substring(box_number from 4)
where box_number like 'SB-%';