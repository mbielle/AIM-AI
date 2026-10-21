-- Protocole remote v2 — R2b : correctifs de la relecture de sécurité du 2026-09-14.

-- 1. Enveloppes : Supabase accorde par défaut TOUS les droits (dont TRUNCATE, qui ignore la RLS).
revoke all on public.remote_device_keys from anon, authenticated;
grant select on public.remote_device_keys to authenticated;
alter table public.remote_device_keys drop constraint if exists remote_device_keys_taille;
alter table public.remote_device_keys add constraint remote_device_keys_taille check (length(envelope::text) < 1024);

-- 2. Commandes : l'ordinateur les fait avancer par une fonction PROUVÉE par son secret,
--    et seulement VERS L'AVANT (pending → ack → done|error). Une commande terminée ne
--    peut plus redevenir « pending » : plus de rejeu d'une commande déjà exécutée.
create or replace function public.remote_update_command(
  p_machine_id uuid, p_secret text, p_command_id uuid, p_status text,
  p_error text default null, p_result jsonb default null
)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  v_n integer;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if not exists (
    select 1 from public.remote_machines
    where id = p_machine_id and user_id = auth.uid()
      and secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex')
  ) then
    return jsonb_build_object('ok', false, 'error', 'machine_secret_mismatch');
  end if;
  if p_error is not null and length(p_error) > 200 then
    return jsonb_build_object('ok', false, 'error', 'invalid_error');
  end if;

  if p_status = 'ack' then
    update public.remote_commands set status = 'ack', acked_at = now()
    where id = p_command_id and machine_id = p_machine_id and user_id = auth.uid() and status = 'pending';
  elsif p_status = 'progress' then
    update public.remote_commands set result = p_result
    where id = p_command_id and machine_id = p_machine_id and user_id = auth.uid() and status = 'ack';
  elsif p_status in ('done', 'error') then
    update public.remote_commands
    set status = p_status, error = p_error, done_at = now(), result = coalesce(p_result, result)
    where id = p_command_id and machine_id = p_machine_id and user_id = auth.uid() and status in ('pending', 'ack');
  else
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;

  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'transition_refused');
  end if;
  return jsonb_build_object('ok', true);
end
$function$;
revoke all on function public.remote_update_command(uuid, text, uuid, text, text, jsonb) from public, anon;
grant execute on function public.remote_update_command(uuid, text, uuid, text, text, jsonb) to authenticated;

-- ⚠️ La règle d'UPDATE directe sur remote_commands sera retirée par R2c, une fois
-- l'app 1.0.277 (qui passe par cette fonction) installée sur les ordinateurs.
