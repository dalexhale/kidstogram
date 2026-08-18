-- kidstogram — 0001_init.sql
-- Schema, RLS and storage policies from docs/launch-plan.md Phases 2–4,
-- plus the game_rounds / game_scores tables.
-- Paste into the Supabase SQL editor and run once, top to bottom.
--
-- Prerequisite (dashboard, Phase 4.1): a Storage bucket called `media`
-- with Public OFF. The storage policies at the bottom assume it exists.

-- ============================================================
-- Extensions
-- ============================================================

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ============================================================
-- Phase 2 — Schema
-- ============================================================

-- ---------- who is allowed in at all ----------
create table allowlist (
  parent_email   citext primary key,
  child_name     text not null,
  is_owner       boolean not null default false,
  added_at       timestamptz not null default now()
);

-- ---------- one row per child ----------
create table profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     citext unique not null check (char_length(username) between 3 and 18),
  real_name    text not null check (char_length(real_name) between 2 and 16),
  parent_email citext not null references allowlist(parent_email),
  is_owner     boolean not null default false,
  suspended    boolean not null default false,
  created_at   timestamptz not null default now()
);

-- ---------- posts ----------
create type post_kind as enum ('photo','video','drawing','made_up');
create type sit_mode  as enum ('stick','jump');

create table posts (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references profiles(id) on delete cascade,
  kind         post_kind not null,
  storage_path text,                       -- null for made-up pictures
  frame_count  int not null default 1,     -- >1 means it's a sprite-sheet video
  drawn_key    text,                       -- e.g. 'cat', when kind = 'made_up'
  bg_key       text,
  bg_colour    text check (bg_colour is null or bg_colour ~ '^#[0-9A-Fa-f]{6}$'),
  sit          sit_mode not null default 'stick',
  fx           text[] not null default '{}' check (array_length(fx,1) is null or array_length(fx,1) <= 3),
  zoom         real not null default 1 check (zoom between 0.2 and 3),
  dx           real not null default 0,
  dy           real not null default 0,
  spin         real not null default 0,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days'
);
create index on posts (expires_at);
create index on posts (created_at desc);

-- ---------- stamps ----------
create table stamps (
  id        uuid primary key default gen_random_uuid(),
  post_id   uuid not null references posts(id) on delete cascade,
  author_id uuid not null references profiles(id) on delete cascade,
  kind      text not null,
  x         real not null,
  y         real not null,
  spin      real not null default 0
);
create index on stamps (post_id);

-- ---------- comments ----------
create table comments (
  id        uuid primary key default gen_random_uuid(),
  post_id   uuid not null references posts(id) on delete cascade,
  author_id uuid not null references profiles(id) on delete cascade,
  body      text not null check (char_length(body) between 1 and 90),
  created_at timestamptz not null default now()
);
create index on comments (post_id);

-- ---------- an audit trail for the kick-out button ----------
create table moderation_events (
  id         uuid primary key default gen_random_uuid(),
  actor_id   uuid references profiles(id),
  target_id  uuid references profiles(id),
  action     text not null,       -- 'suspend' | 'restore' | 'delete_comment'
  detail     text,
  created_at timestamptz not null default now()
);

-- ---------- weekly seeded game rounds ----------
-- Rounds are minted server-side (edge function / cron using the service role
-- key, which bypasses RLS). The client only ever reads them.
-- seed is the integer fed to mulberry32 on the client; bigint because the
-- current week-number * multiplier values overflow int4.
create table game_rounds (
  game_key  text not null,        -- e.g. 'donkey'
  round_key text not null,        -- e.g. the week number, as text
  seed      bigint not null,
  opens_at  timestamptz not null,
  closes_at timestamptz not null,
  primary key (game_key, round_key),
  check (closes_at > opens_at)
);

-- ---------- one score per player per round ----------
create table game_scores (
  round_key  text not null,
  game_key   text not null,
  player_id  uuid not null references profiles(id) on delete cascade,
  points     int not null,
  detail     jsonb,
  created_at timestamptz not null default now(),
  foreign key (game_key, round_key) references game_rounds (game_key, round_key) on delete cascade,
  -- the one-go-per-round rule, enforced by the database not the client
  unique (game_key, round_key, player_id)
);

-- ============================================================
-- Phase 3 — Row Level Security
-- ============================================================

alter table profiles          enable row level security;
alter table posts             enable row level security;
alter table stamps            enable row level security;
alter table comments          enable row level security;
alter table moderation_events enable row level security;
alter table allowlist         enable row level security;   -- no policies = nobody reads it
alter table game_rounds       enable row level security;
alter table game_scores       enable row level security;

-- helper: is the caller an active member?
create or replace function is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and suspended = false
  );
$$;

create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and is_owner = true and suspended = false
  );
$$;

-- ---------- profiles ----------
create policy "members see each other" on profiles
  for select using (is_member());

-- deliberately no INSERT policy: profiles are inserted server-side by the
-- check-allowlist edge function using the service role (which bypasses RLS)
-- after it has verified the parent email. The client never inserts a profile.

create policy "you edit your own profile" on profiles
  for update using (id = auth.uid()) with check (id = auth.uid() and is_owner = (select is_owner from profiles p where p.id = auth.uid()));

create policy "owner can suspend" on profiles
  for update using (is_owner());

-- ---------- posts ----------
create policy "members read posts" on posts
  for select using (is_member() and expires_at > now());

create policy "members post as themselves" on posts
  for insert with check (is_member() and author_id = auth.uid());

create policy "delete own posts, owner deletes any" on posts
  for delete using (is_member() and (author_id = auth.uid() or is_owner()));

-- ---------- stamps ----------
create policy "members read stamps" on stamps for select using (is_member());
create policy "members add own stamps" on stamps
  for insert with check (is_member() and author_id = auth.uid());
create policy "move own stamps, owner moves any" on stamps
  for update using (is_member() and (author_id = auth.uid() or is_owner()))
  with check  (is_member() and (author_id = auth.uid() or is_owner()));
create policy "remove own stamps, owner removes any" on stamps
  for delete using (is_member() and (author_id = auth.uid() or is_owner()));

-- ---------- comments ----------
create policy "members read comments" on comments for select using (is_member());
create policy "members comment as themselves" on comments
  for insert with check (is_member() and author_id = auth.uid());
create policy "delete own comments, owner deletes any" on comments
  for delete using (is_member() and (author_id = auth.uid() or is_owner()));
-- deliberately no UPDATE policy: comments can't be silently edited after the fact

-- ---------- moderation ----------
create policy "owner reads moderation log" on moderation_events for select using (is_owner());
create policy "owner writes moderation log" on moderation_events
  for insert with check (is_owner() and actor_id = auth.uid());

-- ---------- games ----------
-- Rounds: members read; no insert/update/delete policies, so only the
-- service role (edge function / cron) can mint or close a round.
create policy "members read rounds" on game_rounds
  for select using (is_member());

-- Scores: members read all, insert only their own.
create policy "members read scores" on game_scores
  for select using (is_member());
create policy "score as yourself" on game_scores
  for insert with check (
    is_member()
    and player_id = auth.uid()
    and exists (
      select 1 from game_rounds r
      where r.game_key  = game_scores.game_key
        and r.round_key = game_scores.round_key
        and now() between r.opens_at and r.closes_at
    )
  );
-- deliberately no UPDATE or DELETE policy: a submitted go is final

-- ============================================================
-- Phase 4 — Storage policies (bucket `media`, created in the
-- dashboard with Public OFF, path convention {author_id}/{post_id}.jpg)
-- ============================================================

create policy "members read media" on storage.objects
  for select using (bucket_id = 'media' and is_member());

create policy "upload into your own folder" on storage.objects
  for insert with check (
    bucket_id = 'media'
    and is_member()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "delete your own, owner deletes any" on storage.objects
  for delete using (
    bucket_id = 'media' and is_member()
    and ((storage.foldername(name))[1] = auth.uid()::text or is_owner())
  );
