-- PREPARED ONLY. No production application authorized by this source change.
-- Additive paired-Mac protocol; does not alter phone pairing/unlock RPCs.
begin;
create table public.remote_peer_identities (
  machine_id uuid primary key references public.remote_machines(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  identity jsonb not null check (octet_length(identity::text) <= 4096), created_at timestamptz not null default now()
);
create table public.remote_peer_pairs (
  id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
  origin_id uuid not null references public.remote_peer_identities(machine_id) on delete cascade,
  worker_id uuid not null references public.remote_peer_identities(machine_id) on delete cascade,
  origin_identity jsonb not null, worker_identity jsonb not null,
  accepted boolean not null default false, revoked boolean not null default false,
  expires_at timestamptz not null, created_at timestamptz not null default now(), check (origin_id <> worker_id)
);
create table public.remote_peer_commands (
  pair_id uuid not null references public.remote_peer_pairs(id) on delete cascade,
  command_id uuid not null, user_id uuid not null references auth.users(id) on delete cascade,
  from_id uuid not null, to_id uuid not null, packet_text text not null check (octet_length(packet_text) <= 524288),
  reply_text text check (octet_length(reply_text) <= 524288), created_at timestamptz not null default now(),
  primary key(pair_id,command_id), check (from_id <> to_id)
);
create index remote_peer_pending on public.remote_peer_commands(to_id,created_at) where reply_text is null;
alter table public.remote_peer_identities enable row level security;
alter table public.remote_peer_pairs enable row level security;
alter table public.remote_peer_commands enable row level security;
revoke all on public.remote_peer_identities, public.remote_peer_pairs, public.remote_peer_commands from anon, authenticated;

create function public.remote_peer_pair_json_v1(p public.remote_peer_pairs) returns jsonb
language sql immutable set search_path = public as $$
 select jsonb_build_object('id',p.id,'accountID',p.user_id,'origin',p.origin_identity,'worker',p.worker_identity,
   'accepted',p.accepted,'revoked',p.revoked,'expiresAt',extract(epoch from p.expires_at)-978307200);
$$;
revoke all on function public.remote_peer_pair_json_v1(public.remote_peer_pairs) from public, anon, authenticated;

create function public.remote_peer_v1(p_operation text,p_machine_id uuid,p_secret text,p_payload text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
<<peer_rpc>>
declare
 j jsonb; result jsonb; pair public.remote_peer_pairs; existing public.remote_peer_commands;
 own_identity jsonb; other_identity jsonb; peer_id uuid; pair_id uuid; command_id uuid; expiry timestamptz;
begin
 if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_authenticated'); end if;
 if p_secret is null or length(p_secret)<32 or not exists(
   select 1 from public.remote_machines where id=p_machine_id and user_id=auth.uid()
     and secret_hash=encode(digest(p_secret,'sha256'),'hex')
 ) then return jsonb_build_object('ok',false,'error','machine_identity_refused'); end if;
 if p_payload is null or octet_length(p_payload)>524288 then return jsonb_build_object('ok',false,'error','payload_limit'); end if;
 j := p_payload::jsonb;
 if coalesce(jsonb_typeof(j),'')<>'object' then return jsonb_build_object('ok',false,'error','object_required'); end if;
 if p_operation='status' then result := jsonb_build_object('version',1);
 elsif p_operation='register' then
   if not (j ?& array['version','machineID','agreementKey','signingKey']) or coalesce((j->>'version')::int,0)<>1 or (j->>'machineID')::uuid<>p_machine_id
      or coalesce(length(j->>'agreementKey'),0)<>88 or coalesce(length(j->>'signingKey'),0)<>88 then
     return jsonb_build_object('ok',false,'error','invalid_public_identity');
   end if;
   perform pg_advisory_xact_lock(hashtextextended(p_machine_id::text,812));
   select identity into own_identity from public.remote_peer_identities where machine_id=p_machine_id and user_id=auth.uid();
   if own_identity is not null and own_identity<>j and exists(select 1 from public.remote_peer_pairs
     where user_id=auth.uid() and not revoked and (origin_id=p_machine_id or worker_id=p_machine_id)) then
     return jsonb_build_object('ok',false,'error','revoke_pairs_before_rotation');
   end if;
   insert into public.remote_peer_identities(machine_id,user_id,identity) values(p_machine_id,auth.uid(),j)
     on conflict(machine_id) do update set identity=excluded.identity where remote_peer_identities.user_id=auth.uid();
   result := '{}'::jsonb;
 elsif p_operation='identities' then
   select coalesce(jsonb_agg(identity order by machine_id),'[]'::jsonb) into result from public.remote_peer_identities where user_id=auth.uid();
 elsif p_operation='pairs' then
   select coalesce(jsonb_agg(public.remote_peer_pair_json_v1(p) order by p.created_at),'[]'::jsonb) into result
     from public.remote_peer_pairs p where user_id=auth.uid() and (origin_id=p_machine_id or worker_id=p_machine_id);
 elsif p_operation='propose' then
   pair_id := (j->>'pairID')::uuid; peer_id := (j->'peer'->>'machineID')::uuid;
   expiry := to_timestamp((j->>'expiresAt')::double precision+978307200);
   if peer_id=p_machine_id or expiry<=now() or expiry>timestamptz '4001-01-01 00:00:00+00' then
     return jsonb_build_object('ok',false,'error','invalid_pair');
   end if;
   -- Order both identity locks to serialize rotation/proposal without deadlock.
   perform pg_advisory_xact_lock(hashtextextended(least(p_machine_id::text,peer_id::text),812));
   perform pg_advisory_xact_lock(hashtextextended(greatest(p_machine_id::text,peer_id::text),812));
   select identity into own_identity from public.remote_peer_identities where machine_id=p_machine_id and user_id=auth.uid();
   select identity into other_identity from public.remote_peer_identities where machine_id=peer_id and user_id=auth.uid();
   if own_identity is null or other_identity is null or other_identity<>j->'peer' then
     return jsonb_build_object('ok',false,'error','peer_key_mismatch');
   end if;
   insert into public.remote_peer_pairs(id,user_id,origin_id,worker_id,origin_identity,worker_identity,expires_at)
     values(pair_id,auth.uid(),p_machine_id,peer_id,own_identity,other_identity,expiry) on conflict(id) do nothing;
   select * into pair from public.remote_peer_pairs where id=pair_id and user_id=auth.uid();
   if pair.id is null or pair.origin_id<>p_machine_id or pair.worker_id<>peer_id or pair.origin_identity<>own_identity
     or pair.worker_identity<>other_identity or pair.expires_at<>expiry then
     return jsonb_build_object('ok',false,'error','pair_id_conflict');
   end if;
   result := public.remote_peer_pair_json_v1(pair);
 elsif p_operation in ('accept','revoke') then
   select * into pair from public.remote_peer_pairs where id=(j->>'pairID')::uuid and user_id=auth.uid() for update;
   if pair.id is null or p_machine_id not in (pair.origin_id,pair.worker_id) then
     return jsonb_build_object('ok',false,'error','pair_refused');
   end if;
   if p_operation='accept' then
     if p_machine_id<>pair.worker_id or pair.revoked or pair.expires_at<=now()
       or not exists(select 1 from public.remote_peer_identities where machine_id=p_machine_id and identity=pair.worker_identity and user_id=auth.uid()) then
       return jsonb_build_object('ok',false,'error','pair_refused');
     end if;
     update public.remote_peer_pairs set accepted=true where id=pair.id;
   else update public.remote_peer_pairs set revoked=true where id=pair.id; end if;
   result := '{}'::jsonb;
 elsif p_operation='pending' then
   select coalesce(jsonb_agg(q.packet_text::jsonb order by q.created_at,q.command_id),'[]'::jsonb) into result from (
     select c.* from public.remote_peer_commands c join public.remote_peer_pairs p on p.id=c.pair_id
     where c.user_id=auth.uid() and c.to_id=p_machine_id and c.reply_text is null and p.accepted and not p.revoked and p.expires_at>now()
     order by c.created_at,c.command_id limit 20
   ) q;
 elsif p_operation in ('submit','reply','receipt') then
   pair_id := (j->>'pairID')::uuid; command_id := (j->>'commandID')::uuid;
   select * into pair from public.remote_peer_pairs where id=pair_id and user_id=auth.uid() for share;
   if pair.id is null or not pair.accepted or pair.revoked or pair.expires_at<=now()
      or p_machine_id not in (pair.origin_id,pair.worker_id) then
     return jsonb_build_object('ok',false,'error','pair_refused');
   end if;
   if p_operation='receipt' then
     select reply_text::jsonb into result from public.remote_peer_commands where remote_peer_commands.pair_id=pair.id and remote_peer_commands.command_id=peer_rpc.command_id
       and user_id=auth.uid() and from_id=p_machine_id;
     result := coalesce(result,'null'::jsonb);
   else
     if not (j ?& array['version','accountID','from','to','kind','signature','ciphertext']) or coalesce((j->>'version')::int,0)<>1 or (j->>'accountID')::uuid<>auth.uid() or (j->>'from')::uuid<>p_machine_id
       or (j->>'to')::uuid not in (pair.origin_id,pair.worker_id) or (j->>'to')::uuid=p_machine_id
       or coalesce(length(j->>'signature'),0)<80 or coalesce(length(j->>'ciphertext'),0)<40 then
       return jsonb_build_object('ok',false,'error','invalid_envelope');
     end if;
     if p_operation='submit' then
       if j->>'kind'<>'request' then return jsonb_build_object('ok',false,'error','invalid_kind'); end if;
       insert into public.remote_peer_commands(pair_id,command_id,user_id,from_id,to_id,packet_text)
         values(pair.id,command_id,auth.uid(),p_machine_id,(j->>'to')::uuid,p_payload) on conflict(pair_id,command_id) do nothing;
       select * into existing from public.remote_peer_commands c where c.pair_id=pair.id and c.command_id=peer_rpc.command_id;
       if existing.user_id<>auth.uid() or existing.from_id<>p_machine_id or existing.packet_text<>p_payload then
         return jsonb_build_object('ok',false,'error','command_id_conflict');
       end if;
     else
       if j->>'kind'<>'reply' then return jsonb_build_object('ok',false,'error','invalid_kind'); end if;
       select * into existing from public.remote_peer_commands c where c.pair_id=pair.id and c.command_id=peer_rpc.command_id for update;
       if existing.command_id is null or existing.user_id<>auth.uid() or existing.to_id<>p_machine_id or existing.from_id<>(j->>'to')::uuid
         or (existing.reply_text is not null and existing.reply_text<>p_payload) then
         return jsonb_build_object('ok',false,'error','reply_id_conflict');
       end if;
       update public.remote_peer_commands c set reply_text=p_payload where c.pair_id=pair.id and c.command_id=peer_rpc.command_id;
     end if;
     result := '{}'::jsonb;
   end if;
 else return jsonb_build_object('ok',false,'error','unsupported_operation'); end if;
 return jsonb_build_object('ok',true,'payload_text',result::text);
exception when invalid_text_representation or numeric_value_out_of_range or datetime_field_overflow then
 return jsonb_build_object('ok',false,'error','invalid_payload');
end;
$$;
revoke all on function public.remote_peer_v1(text,uuid,text,text) from public, anon;
grant execute on function public.remote_peer_v1(text,uuid,text,text) to authenticated;
commit;
