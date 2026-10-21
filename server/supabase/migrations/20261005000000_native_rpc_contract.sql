-- Native clients use the nine-argument command contract. Earlier overloads were
-- retained by historical CREATE OR REPLACE migrations and must not remain public.
-- This is clean-bootstrap only; deployed instances require a separate review.
do $$ declare f record;begin
for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='remote_send_command' and p.pronargs<>9 loop
 execute format('drop function %s',f.signature);
end loop;end $$;
