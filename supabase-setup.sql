-- ============================================================
-- LiveYou · configuración de Supabase
-- Pégalo completo en: Supabase → SQL Editor → New query → Run
-- Se puede ejecutar más de una vez sin romper nada.
-- ============================================================

-- ---------- PERFILES (nombre de usuario público de cada cuenta de Google) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_.]{3,20}$'),
  avatar text,
  created_at timestamptz not null default now()
);

-- editar perfil: nombre visible, biografía y enlace (se pueden ejecutar varias veces)
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists link text;
alter table public.profiles drop constraint if exists profiles_display_name_len;
alter table public.profiles add constraint profiles_display_name_len check (display_name is null or char_length(display_name) <= 30);
alter table public.profiles drop constraint if exists profiles_bio_len;
alter table public.profiles add constraint profiles_bio_len check (bio is null or char_length(bio) <= 150);
alter table public.profiles drop constraint if exists profiles_link_fmt;
alter table public.profiles add constraint profiles_link_fmt check (link is null or (char_length(link) <= 100 and link ~* '^https?://[^[:space:]]+$'));
alter table public.profiles drop constraint if exists profiles_avatar_fmt;
alter table public.profiles add constraint profiles_avatar_fmt check (avatar is null or (char_length(avatar) <= 500 and avatar ~ '^https://'));

-- ---------- VIDEOS ----------
create table if not exists public.videos (
  id text primary key check (char_length(id) <= 64),          -- SHA-256 del video
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  owner text not null,                                         -- username público
  cap text not null check (char_length(cap) <= 100),
  size bigint not null,
  path text not null,
  src text not null unique,                                    -- huella del original: evita duplicados
  created_at timestamptz not null default now()
);

-- ---------- ME GUSTA / GUARDADOS / SEGUIDOS / COMENTARIOS / NOTAS ----------
create table if not exists public.likes (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  video_id text not null check (char_length(video_id) <= 64),
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);
create table if not exists public.saves (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  video_id text not null check (char_length(video_id) <= 64),
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);
create table if not exists public.follows (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  owner text not null check (char_length(owner) <= 24),
  created_at timestamptz not null default now(),
  primary key (user_id, owner)
);
create table if not exists public.comments (
  id bigint generated always as identity primary key,
  video_id text not null check (char_length(video_id) <= 64),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  username text not null,
  text text not null check (char_length(text) between 1 and 200),
  created_at timestamptz not null default now()
);
create table if not exists public.notes (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 200),
  created_at timestamptz not null default now()
);

create index if not exists likes_video_idx on public.likes(video_id);
create index if not exists comments_video_idx on public.comments(video_id, created_at);
create index if not exists videos_created_idx on public.videos(created_at desc);

-- ---------- CONTADORES (me gusta y comentarios por video) ----------
create or replace view public.video_stats with (security_invoker = true) as
select video_id, sum(l)::bigint as likes, sum(c)::bigint as comments
from (
  select video_id, count(*) as l, 0 as c from public.likes group by video_id
  union all
  select video_id, 0, count(*) from public.comments group by video_id
) t
group by video_id;

-- ---------- SEGURIDAD (RLS) ----------
alter table public.profiles enable row level security;
alter table public.videos   enable row level security;
alter table public.likes    enable row level security;
alter table public.saves    enable row level security;
alter table public.follows  enable row level security;
alter table public.comments enable row level security;
alter table public.notes    enable row level security;

-- perfiles: todos los ven; cada quien edita SOLO el suyo y SOLO nombre/bio/enlace/foto (ver sección EDITAR PERFIL)
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select using (true);

-- videos: todos los ven; solo el dueño sube/borra, y con su propio username
drop policy if exists videos_read on public.videos;
create policy videos_read on public.videos for select using (true);
drop policy if exists videos_ins on public.videos;
create policy videos_ins on public.videos for insert to authenticated
  with check (
    user_id = auth.uid()
    and owner = (select username from public.profiles where id = auth.uid())
    and path like auth.uid()::text || '/%'
  );
drop policy if exists videos_del on public.videos;
create policy videos_del on public.videos for delete to authenticated using (user_id = auth.uid());

-- likes: lectura pública (solo para contar), cada quien maneja los suyos
drop policy if exists likes_read on public.likes;
create policy likes_read on public.likes for select using (true);
drop policy if exists likes_ins on public.likes;
create policy likes_ins on public.likes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists likes_del on public.likes;
create policy likes_del on public.likes for delete to authenticated using (user_id = auth.uid());

-- guardados / seguidos / notas: privados
drop policy if exists saves_all on public.saves;
create policy saves_all on public.saves for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists follows_all on public.follows;
create policy follows_all on public.follows for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists notes_all on public.notes;
create policy notes_all on public.notes for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- comentarios: públicos; solo escribes/borras los tuyos y con tu username real
drop policy if exists comments_read on public.comments;
create policy comments_read on public.comments for select using (true);
drop policy if exists comments_ins on public.comments;
create policy comments_ins on public.comments for insert to authenticated
  with check (user_id = auth.uid() and username = (select username from public.profiles where id = auth.uid()));
drop policy if exists comments_del on public.comments;
create policy comments_del on public.comments for delete to authenticated using (user_id = auth.uid());

-- ---------- PERFIL AUTOMÁTICO AL ENTRAR CON GOOGLE ----------
-- Crea el username a partir del correo (lo que va antes de la @). Si ya existe, le agrega números.
-- También copia tu nombre y foto de Google como valores iniciales (luego los puedes editar).
create or replace function public.ensure_profile()
returns text language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  u text; b text; em text; av text; dn text;
begin
  if uid is null then raise exception 'No has iniciado sesión'; end if;
  select username into u from public.profiles where id = uid;
  if u is not null then return u; end if;

  select email,
         coalesce(raw_user_meta_data->>'avatar_url', raw_user_meta_data->>'picture'),
         left(coalesce(raw_user_meta_data->>'full_name', raw_user_meta_data->>'name'), 30)
    into em, av, dn from auth.users where id = uid;
  b := lower(regexp_replace(split_part(coalesce(em, 'user'), '@', 1), '[^a-z0-9_.]', '', 'g'));
  if length(b) < 3 then b := 'user' || b; end if;
  b := left(b, 16);
  u := b;
  while exists (select 1 from public.profiles where username = u) loop
    u := b || floor(random() * 900 + 100)::int;
  end loop;

  insert into public.profiles (id, username, avatar, display_name) values (uid, u, av, dn);
  return u;
end $$;
revoke all on function public.ensure_profile() from public, anon;
grant execute on function public.ensure_profile() to authenticated;

-- ---------- BORRAR MI CUENTA ----------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------- LIMPIEZA: al borrar un video se borran sus likes, guardados y comentarios ----------
create or replace function public.cleanup_video()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.likes    where video_id = old.id;
  delete from public.saves    where video_id = old.id;
  delete from public.comments where video_id = old.id;
  return old;
end $$;
drop trigger if exists trg_cleanup_video on public.videos;
create trigger trg_cleanup_video after delete on public.videos
  for each row execute function public.cleanup_video();

-- ---------- ALMACENAMIENTO DE VIDEOS ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', true, 10485760, array['video/webm', 'video/mp4'])
on conflict (id) do update
  set public = true, file_size_limit = 10485760, allowed_mime_types = array['video/webm', 'video/mp4'];

drop policy if exists videos_storage_ins on storage.objects;
create policy videos_storage_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists videos_storage_del on storage.objects;
create policy videos_storage_del on storage.objects for delete to authenticated
  using (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============================================================
-- EDITAR PERFIL
-- ============================================================

-- Cada usuario puede actualizar su propia fila. Con permisos por columna, el username NO se puede cambiar.
drop policy if exists profiles_upd on public.profiles;
create policy profiles_upd on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from anon, authenticated;
grant update (display_name, bio, link, avatar) on public.profiles to authenticated;

-- Contadores del perfil (seguidores, siguiendo, me gusta recibidos, videos).
-- Es "security definer" porque la tabla follows es privada: solo se devuelven números, nunca quién sigue a quién.
create or replace function public.profile_stats(p_username text)
returns table (followers bigint, following bigint, likes bigint, videos bigint)
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from public.follows f where f.owner = p_username),
    (select count(*) from public.follows f join public.profiles p on p.id = f.user_id where p.username = p_username),
    (select count(*) from public.likes l join public.videos v on v.id = l.video_id where v.owner = p_username),
    (select count(*) from public.videos v where v.owner = p_username);
$$;
revoke all on function public.profile_stats(text) from public;
grant execute on function public.profile_stats(text) to anon, authenticated;

-- Fotos de perfil: bucket público, una sola imagen JPEG (máx. 1 MB) por usuario, en su propia carpeta.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do update
  set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

drop policy if exists avatars_sel on storage.objects;
create policy avatars_sel on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists avatars_ins on storage.objects;
create policy avatars_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_upd on storage.objects;
create policy avatars_upd on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_del on storage.objects;
create policy avatars_del on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
