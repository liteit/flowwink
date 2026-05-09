
-- ── river_posts ───────────────────────────────────────────────
create table if not exists public.river_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid(),
  body text not null default '',
  media_urls jsonb not null default '[]'::jsonb,
  parent_id uuid references public.river_posts(id) on delete cascade,
  pinned boolean not null default false,
  reply_count integer not null default 0,
  reaction_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists river_posts_created_idx on public.river_posts (created_at desc);
create index if not exists river_posts_parent_idx on public.river_posts (parent_id);
create index if not exists river_posts_author_idx on public.river_posts (author_id);

alter table public.river_posts enable row level security;

drop policy if exists "river_posts read authed" on public.river_posts;
create policy "river_posts read authed" on public.river_posts
  for select to authenticated using (true);

drop policy if exists "river_posts insert own" on public.river_posts;
create policy "river_posts insert own" on public.river_posts
  for insert to authenticated with check (author_id = auth.uid());

drop policy if exists "river_posts update own" on public.river_posts;
create policy "river_posts update own" on public.river_posts
  for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());

drop policy if exists "river_posts admin update" on public.river_posts;
create policy "river_posts admin update" on public.river_posts
  for update to authenticated using (public.has_role(auth.uid(), 'admin')) with check (true);

drop policy if exists "river_posts delete own or admin" on public.river_posts;
create policy "river_posts delete own or admin" on public.river_posts
  for delete to authenticated using (author_id = auth.uid() or public.has_role(auth.uid(), 'admin'));

-- updated_at trigger
create or replace function public.river_posts_stamp()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists river_posts_stamp_trg on public.river_posts;
create trigger river_posts_stamp_trg before update on public.river_posts
  for each row execute function public.river_posts_stamp();

-- ── river_reactions ───────────────────────────────────────────
create table if not exists public.river_reactions (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.river_posts(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  emoji text not null,
  created_at timestamptz not null default now(),
  unique (post_id, user_id, emoji)
);

create index if not exists river_reactions_post_idx on public.river_reactions (post_id);

alter table public.river_reactions enable row level security;

drop policy if exists "river_reactions read authed" on public.river_reactions;
create policy "river_reactions read authed" on public.river_reactions
  for select to authenticated using (true);

drop policy if exists "river_reactions insert own" on public.river_reactions;
create policy "river_reactions insert own" on public.river_reactions
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "river_reactions delete own" on public.river_reactions;
create policy "river_reactions delete own" on public.river_reactions
  for delete to authenticated using (user_id = auth.uid());

-- ── counters: keep reply_count + reaction_count in sync ──────
create or replace function public.river_bump_reply_count()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'INSERT' and new.parent_id is not null) then
    update public.river_posts set reply_count = reply_count + 1 where id = new.parent_id;
  elsif (tg_op = 'DELETE' and old.parent_id is not null) then
    update public.river_posts set reply_count = greatest(reply_count - 1, 0) where id = old.parent_id;
  end if;
  return null;
end;
$$;

drop trigger if exists river_posts_reply_count_trg on public.river_posts;
create trigger river_posts_reply_count_trg
  after insert or delete on public.river_posts
  for each row execute function public.river_bump_reply_count();

create or replace function public.river_bump_reaction_count()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'INSERT') then
    update public.river_posts set reaction_count = reaction_count + 1 where id = new.post_id;
  elsif (tg_op = 'DELETE') then
    update public.river_posts set reaction_count = greatest(reaction_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end;
$$;

drop trigger if exists river_reactions_count_trg on public.river_reactions;
create trigger river_reactions_count_trg
  after insert or delete on public.river_reactions
  for each row execute function public.river_bump_reaction_count();

-- ── realtime ─────────────────────────────────────────────────
alter table public.river_posts replica identity full;
alter table public.river_reactions replica identity full;

do $$ begin
  begin
    alter publication supabase_realtime add table public.river_posts;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.river_reactions;
  exception when duplicate_object then null; end;
end $$;

-- ── storage bucket ───────────────────────────────────────────
insert into storage.buckets (id, name, public)
  values ('river-media', 'river-media', true)
on conflict (id) do nothing;

drop policy if exists "river-media public read" on storage.objects;
create policy "river-media public read" on storage.objects
  for select using (bucket_id = 'river-media');

drop policy if exists "river-media authed upload" on storage.objects;
create policy "river-media authed upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'river-media');

drop policy if exists "river-media owner delete" on storage.objects;
create policy "river-media owner delete" on storage.objects
  for delete to authenticated using (bucket_id = 'river-media' and owner = auth.uid());
