import fs from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
export async function platformFixture() {
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create schema storage;create schema extensions;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');
create table auth.sessions(id uuid primary key,user_id uuid,created_at timestamptz default now(),updated_at timestamptz default now(),refreshed_at timestamptz,not_after timestamptz,user_agent text);
create table auth.refresh_tokens(id serial primary key,user_id text,session_id uuid,revoked boolean default false);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),'authenticated')$$;
create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('session_id',current_setting('request.jwt.claim.session_id',true))$$;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(text) returns text[] language sql immutable as $$ select p[1:array_length(p,1)-1] from (select string_to_array($1,'/') p) x $$;
create function storage.allow_any_operation(text[]) returns boolean language sql stable as $$select coalesce(current_setting('storage.operation',true)=any($1),false)$$;
create function storage.filename(text) returns text language sql immutable as $$select (string_to_array($1,'/'))[array_length(string_to_array($1,'/'),1)]$$;
create publication supabase_realtime;`);
  return db;
}
