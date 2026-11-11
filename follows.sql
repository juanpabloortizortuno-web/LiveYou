create table if not exists public.follows (
  follower_id  uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);
alter table public.follows enable row level security;
create policy "ver follows"    on public.follows for select using (true);
create policy "seguir"         on public.follows for insert with check (auth.uid() = follower_id);
create policy "dejar de seguir" on public.follows for delete using (auth.uid() = follower_id);
