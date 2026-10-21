-- Ids sessions/messages en text : les ids locaux sont des UUID aujourd'hui,
-- mais d'anciennes sessions localStorage peuvent porter d'autres formats et
-- la V2 (création à distance) n'a pas à être contrainte. Tables vides
-- (vérifié) ; machines/commands gardent leurs uuid (générés par nous).
alter table public.remote_messages drop constraint remote_messages_session_id_fkey;
alter table public.remote_commands drop constraint remote_commands_session_id_fkey;

alter table public.remote_sessions alter column id type text using id::text;
alter table public.remote_messages alter column id type text using id::text;
alter table public.remote_messages alter column session_id type text using session_id::text;
alter table public.remote_commands alter column session_id type text using session_id::text;

alter table public.remote_messages
  add constraint remote_messages_session_id_fkey
  foreign key (session_id) references public.remote_sessions(id) on delete cascade;
alter table public.remote_commands
  add constraint remote_commands_session_id_fkey
  foreign key (session_id) references public.remote_sessions(id) on delete set null;