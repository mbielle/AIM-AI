-- Appairage — v3 : limite d'appareils actifs à 5 par compte. Au-delà, les plus
-- ANCIENS sont automatiquement révoqués (demande Mathieu : plafond + éviction).
-- Sécurité inchangée par ailleurs (code consommé, secret d'appareil haché).

create or replace function public.remote_pair_device(p_code text, p_device_id uuid, p_device_secret text, p_device_name text DEFAULT 'Appareil'::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_row public.remote_pairing_codes%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_device_secret is null or length(p_device_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;

  select * into v_row from public.remote_pairing_codes
  where user_id = auth.uid()
    and consumed_at is null
    and expires_at > now()
    and code_hash = encode(digest(p_code, 'sha256'), 'hex')
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_or_expired_code');
  end if;

  update public.remote_pairing_codes set consumed_at = now() where id = v_row.id;

  insert into public.remote_devices (id, user_id, name, secret_hash, expires_at)
  values (
    p_device_id, auth.uid(), coalesce(nullif(p_device_name, ''), 'Appareil'),
    encode(digest(p_device_secret, 'sha256'), 'hex'),
    now() + interval '90 days'
  )
  on conflict (id) do update
    set secret_hash = excluded.secret_hash,
        name = excluded.name,
        paired_at = now(),
        expires_at = excluded.expires_at,
        revoked_at = null;

  -- Plafond : ne garder que les 5 appareils actifs les plus récents.
  update public.remote_devices
  set revoked_at = now()
  where user_id = auth.uid()
    and revoked_at is null
    and id not in (
      select id from public.remote_devices
      where user_id = auth.uid() and revoked_at is null
      order by paired_at desc
      limit 5
    );

  return jsonb_build_object('ok', true);
end
$function$;