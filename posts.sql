create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  body text default '',
  image_url text,
  for_sale boolean default false,
  price numeric,
  currency text,
  created_at timestamptz default now()
);
alter table public.posts enable row level security;
create policy "ver posts" on public.posts for select using (true);
create policy "crear post" on public.posts for insert with check (auth.uid() = user_id);
create policy "borrar mi post" on public.posts for delete using (auth.uid() = user_id);
