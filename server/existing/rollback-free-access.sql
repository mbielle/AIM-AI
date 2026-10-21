-- Restore only backed-up function definitions, never delete user data.
begin;
do $$ declare row record; begin
 if to_regclass('aim_transition_private.function_backups') is null then raise exception 'transition_backup_missing';end if;
 for row in select definition from aim_transition_private.function_backups loop execute row.definition;end loop;
end $$;
commit;
