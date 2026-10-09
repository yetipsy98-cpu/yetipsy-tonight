-- Remove the original seeded test label without changing activity IDs or issued passes.
update public.campaigns set name='Yetipsy Play' where name='Yetipsy Play V1 · 内部测试';
