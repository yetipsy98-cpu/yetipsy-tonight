alter table private.yt_ff_stock drop constraint yt_ff_stock_product_id_fkey;
alter table private.yt_ff_stock add constraint yt_ff_stock_product_id_fkey foreign key(product_id) references public.yt_shop_products(id) on delete cascade;
