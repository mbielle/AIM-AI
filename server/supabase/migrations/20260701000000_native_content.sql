-- Native cloud content foundation for NEW installations only.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create table public.profiles(id uuid primary key references auth.users(id) on delete cascade,email text,full_name text,preferred_name text,personal_preferences text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.projects(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,name text not null,description text,custom_context text,default_language text default 'auto',archived boolean not null default false,is_starred boolean not null default false,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),last_active_at timestamptz not null default now());
create table public.conversations(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,project_id uuid references public.projects(id) on delete set null,title text not null default '',current_model text,archived boolean not null default false,is_pinned boolean not null default false,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.messages(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,conversation_id uuid not null references public.conversations(id) on delete cascade,role text not null,content text not null default '',reasoning text,model text,created_at timestamptz not null default now());
create table public.project_files(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,project_id uuid not null references public.projects(id) on delete cascade,name text not null,mime_type text,size_bytes bigint not null default 0,status text not null default 'uploading',processing_status text,storage_path text,extracted_content text,error_message text,indexed_at timestamptz,created_at timestamptz not null default now());
create table public.user_connectors(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,connector_type text not null,display_name text not null,server_url text not null,config jsonb,is_active boolean not null default false,last_connected_at timestamptz,tools_cache jsonb,default_parent_id text,default_parent_name text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.user_memory_documents(user_id uuid primary key references auth.users(id) on delete cascade,content_md text not null default '',version bigint not null default 1,updated_at timestamptz not null default now());
create table public.user_preferences(user_id uuid primary key references auth.users(id) on delete cascade,auto_model_selection boolean,auto_title_generation boolean,smart_context boolean,haptic_feedback boolean,tone text,style text,expertise text,length_instruction text,emojis boolean,max_emojis int,web_search_enabled boolean,detailed_response_enabled boolean,library_retention_days int,share_profile_with_ai boolean,memory_enabled boolean);
create table public.generated_images(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,image_url text not null,prompt text not null,model_used text not null,storage_path text,created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '30 days');
create table public.generated_videos(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,video_url text not null,prompt text not null,model_used text not null,storage_path text,duration double precision,resolution text,status text not null default 'completed',created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '30 days');
alter table public.profiles enable row level security;
create policy profiles_own on public.profiles for all to authenticated using(id=auth.uid()) with check(id=auth.uid());
do $$ declare t text; begin
 foreach t in array array['projects','conversations','messages','project_files','user_connectors','user_preferences','user_memory_documents','generated_images','generated_videos'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy %I on public.%I for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid())',t||'_own',t);
 end loop;
end $$;
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$ begin insert into public.profiles(id,email,full_name) values(new.id,new.email,new.raw_user_meta_data->>'full_name');return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
insert into storage.buckets(id,name,public) values('project-files-user','project-files-user',false) on conflict(id) do nothing;
create policy native_project_files_own on storage.objects for all to authenticated using(bucket_id='project-files-user' and (storage.foldername(name))[1]=auth.uid()::text) with check(bucket_id='project-files-user' and (storage.foldername(name))[1]=auth.uid()::text);
-- A message/file may reference only a parent belonging to the same account.
create function public.native_content_parent_owner() returns trigger language plpgsql set search_path='' as $$ begin
 if tg_table_name='messages' then if not exists(select 1 from public.conversations where id=new.conversation_id and user_id=new.user_id) then raise exception 'conversation_not_owned' using errcode='42501'; end if;end if;
 if tg_table_name in ('project_files','conversations') then if new.project_id is not null and not exists(select 1 from public.projects where id=new.project_id and user_id=new.user_id) then raise exception 'project_not_owned' using errcode='42501';end if;end if;
 return new; end $$;
create trigger messages_parent_owner before insert or update on public.messages for each row execute function public.native_content_parent_owner();
create trigger project_files_parent_owner before insert or update on public.project_files for each row execute function public.native_content_parent_owner();

create trigger conversations_parent_owner before insert or update on public.conversations for each row execute function public.native_content_parent_owner();
