# kidstogram — launch plan

From working front end to a live, private, secure app for four children.

Stack: Supabase (Postgres + Auth + Storage) and Vercel (static hosting). Both already paid for.

---

## Phase 0 — Decide these before writing any code

These are not code problems and they will bite you later if you skip them.

**0.1 — Fix the group size and membership.**
Four kids, four parent accounts. Not "and their friends too." The security model below depends on a closed, hand-maintained list. Growth breaks it.

**0.2 — Get explicit written consent from each parent.**
Email is fine. Say plainly:
- Photos their child uploads will be stored on your Supabase project
- Which region the data sits in
- That all four children and all four parents can see everything posted
- That posts auto-delete after 7 days
- That you can export or delete their child's data on request within a few days
- Who to contact (you)

Keep the replies. This is the single most valuable thing in this document.

**0.3 — Understand your position.**
Once other families' children's photos are on infrastructure you control, you are acting as a data controller. The UK GDPR "domestic purposes" exemption is arguable for something this small and private, but it is not a certainty, and the ICO's Age Appropriate Design Code exists precisely for services aimed at children. I'm not a lawyer and this isn't legal advice — but be upfront with the parents, keep the group tiny, and don't let it grow into something public.

**0.4 — Decide the moderation rule now, in writing.**
Libby's kick-out button should flag and notify, not silently delete a child. Agree with the other parents what happens when it's pressed. Recommended: account suspended immediately, all four parents emailed, you and the other parent decide within 24 hours.

---

## Phase 1 — Supabase project

**1.1** New project. **Region: London (eu-west-2).** Keeps UK children's data in the UK, simplifies everything in 0.3.

**1.2** Enable Google as an auth provider. Dashboard → Authentication → Providers → Google. You'll need OAuth credentials from Google Cloud Console with your Vercel domain as an authorised redirect URI.

**1.3** Turn everything else off:
- Email/password signup: **disabled**
- Anonymous sign-in: **disabled**
- Sign-ups in general: leave on (the allowlist is the real gate), but see 5.2

**1.4** Enable extensions: `pgcrypto`, `citext`, `pg_cron`.

---

## Phase 2 — Schema

Run this in the SQL editor.

```sql
create extension if not exists pgcrypto;
create extension if not exists citext;

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
```

Seed the allowlist with the four parent emails, marking your own row `is_owner = true`.

---

## Phase 3 — Row Level Security

**This is the part that actually keeps the photos private.** Everything is deny-by-default until a policy says otherwise.

```sql
alter table profiles          enable row level security;
alter table posts             enable row level security;
alter table stamps            enable row level security;
alter table comments          enable row level security;
alter table moderation_events enable row level security;
alter table allowlist         enable row level security;   -- no policies = nobody reads it

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

-- deliberately no INSERT policy on profiles: an insert policy can't check the
-- allowlist (policy subqueries run as the calling user, and allowlist has no
-- read policy, so the check would always fail). Profiles are created by the
-- check-allowlist edge function with the service role instead — see 5.2.

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
```

**Test these before you trust them.** In the SQL editor, `set request.jwt.claims` to impersonate each child and confirm a suspended user reads nothing.

---

## Phase 4 — Storage

**4.1** Create a bucket called `media`. **Public: off.** This is the single most important toggle in the project.

**4.2** Path convention: `{author_id}/{post_id}.jpg`. Putting the owner's UUID first is what makes the policy below simple.

**4.3** Policies on `storage.objects`:

```sql
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
```

**4.4** Never render a public URL. Fetch with `createSignedUrl(path, 3600)` and cache the result in memory for the session.

---

## Phase 5 — Auth flow

**5.1** Sign in with Google. This is the parent's account, on the parent's phone or the family tablet — that's the point. The parent is the credential.

**5.2** After the OAuth callback, before showing anything:

```
session.user.email
  → look up in allowlist (via an edge function using the service role key,
    because allowlist has no read policy)
  → not found?  sign out immediately, show "ask your grown-up to set this up"
  → found, no profile yet?  show the username / real name screen, insert profile
  → found, profile exists, suspended? show a calm message, no wall
  → otherwise: the PIN unlock (5.3), then the wall
```

Do the allowlist check server-side in an edge function. If you do it in the browser you're trusting the client, which defeats it.

The same edge function also **inserts the profile row with the service role** after the allowlist check passes (taking the username / real name from the request). There is deliberately no INSERT policy on `profiles`, so this is the only way a profile can be created.

**5.3** The 9-digit PIN — a device unlock, as built.
Keep it — Libby designed it and it's a nice bit of UI. But it is **not** the credential. It's a device unlock on top of an already-authenticated Google session, so a kid can hand the tablet to a sibling without handing over the wall.

- At profile creation the PIN is bcrypt-hashed in the browser (bcryptjs, cost 10)
  and stored on the profile as `pin_hash` by the check-allowlist edge function.
- On a later visit, when a stored session and a profile already exist, an unlock
  screen asks for the 9 numbers before the wall. The hash comes back through
  `my_pin_hash()` (security definer, caller's own row only — column grants keep
  `pin_hash` and `parent_email` out of the members' profiles select entirely)
  and is checked client-side with bcrypt.compare.
- A fresh interactive Google sign-in — the redirect straight back from Google —
  skips the unlock once. The parent is the credential, so "I forgot it" on the
  unlock screen signs out, and a grown-up signing in again is the recovery path.
  A session quietly restored from storage never skips it.
- The PIN gates nothing server-side, ever.

Do not explain this distinction to Libby as "your password doesn't count." It does count — it just isn't the front door.

---

## Phase 6 — Changes to the front end

The current `index-v13.html` is a complete UI running on fake in-memory data. The port is mostly: replace the `posts`, `friends` and `realNames` variables with Supabase queries, and replace the data-URL images with signed URLs.

**6.1 — EXIF is already handled, by luck.**
Every capture path goes through `canvas.drawImage()` then `toDataURL()`. Canvas re-encoding discards all EXIF, including GPS. Do not "improve" this by uploading the original `File` object from the file picker — that would reintroduce the problem. Keep the canvas step.

**6.2 — Upload blobs, not data URLs.**
`canvas.toBlob(blob => supabase.storage.from('media').upload(path, blob))`. Data URLs are ~33% larger and will make the wall crawl.

**6.3 — Videos: one file, not twenty.**
The player already works by sliding a wide strip of frames. So composite the 20 frames into a **single wide sprite-sheet JPEG** at upload time (one canvas, 20 × 400px wide), store `frame_count = 20`, and the existing CSS `steps()` animation works unchanged against one file. One upload, one signed URL, one fetch.

**6.4 — Resize before upload.** 400px for video frames, 800px for stills is plenty for a tablet. Cap uploads at ~2 MB in the client and reject above that.

**6.5 — The username uniqueness check** currently uses an in-memory `Set`. Replace with a lookup against `profiles`, and rely on the `unique` constraint as the real guard — two kids can tap at the same moment.

**6.6 — Realtime (optional).** `supabase.channel()` on `posts`, `stamps` and `comments` makes stamps appear live on other tablets. Genuinely delightful for kids in the same house. Add it after launch, not before.

---

## Phase 7 — The 7-day delete

Deleting a `posts` row does **not** delete the file in Storage. You need both.

**7.1** Edge function `sweep`:

```ts
// select id, storage_path from posts where expires_at < now()
// storage.from('media').remove(paths)
// delete from posts where expires_at < now()
```

Uses the service role key. Never expose that key to the browser.

**7.2** Schedule it hourly:

```sql
select cron.schedule(
  'sweep-expired',
  '0 * * * *',
  $$ select net.http_post(
       url := 'https://<project>.functions.supabase.co/sweep',
       headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb
     ); $$
);
```

**7.3** Also run it once manually and confirm the file actually disappears from the bucket. This is the step everyone assumes worked.

---

## Phase 8 — Moderation

**8.1** The kick-out button sets `suspended = true` and inserts a `moderation_events` row. It does not delete the child or their posts.

**8.2** A database webhook on `moderation_events` insert → edge function → email all four parents. Resend or Postmark; either is a few lines.

**8.3** Give yourself a restore path. A `suspended = false` update from your own owner account is enough — you don't need a UI for it on day one.

**8.4** Parent view: you're already `is_owner`, so you see everything through the normal app. That's sufficient. Don't build a separate admin panel.

---

## Phase 9 — Vercel

**9.1** Connect the repo. Static site, no build step needed for a single HTML file — though moving to a small Vite project will be easier once there's real JS.

**9.2** Env vars: `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. Both are safe in the browser — the anon key is designed to be public, and RLS is what protects the data. **The service role key never goes near Vercel's client bundle.** Edge function secrets live in Supabase.

**9.3** Custom domain with HTTPS. Required — `getUserMedia` will not run on plain HTTP, so the camera silently fails.

**9.4** Turn on Vercel deployment protection for preview branches so half-finished versions aren't publicly reachable.

**9.5** Add a `robots.txt` disallowing everything, and `<meta name="robots" content="noindex">`. It's behind auth anyway, but there's no reason for the login page to be indexed.

---

## Phase 10 — Before the kids touch it

- [ ] Sign in as a Google account **not** on the allowlist → rejected
- [ ] Sign in as an allowlisted parent → username screen → wall
- [ ] Post a photo, then copy the signed URL and open it in a private window after an hour → dead link
- [ ] Try to fetch another child's storage path directly with your anon key → denied
- [ ] Suspend a test account → confirm it reads nothing at all
- [ ] Manually set a post's `expires_at` to the past, run the sweep, confirm the row **and the file** are gone
- [ ] Camera on the actual tablets, in the actual house, in evening light
- [ ] iOS Safari specifically — the most likely thing to break
- [ ] Post 30 items and check the wall still scrolls smoothly

---

## Things that will probably bite you

**iOS Safari and `getUserMedia`.** Works in Safari proper. Historically unreliable inside home-screen web apps and in-app browsers. Test on the real device early — this is the highest-risk item in the whole build.

**HEIC.** iPhone photos via the file-picker fallback come through as HEIC and some browsers won't decode them. The camera path is fine (canvas). The file-picker path needs a graceful failure message.

**The "jump inside it" cut-out.** It's a feathered oval, not real segmentation. Libby knows this and accepted it. If it disappoints in practice, MediaPipe Selfie Segmentation is the upgrade — but it's an external dependency, it's ~2 MB, and it breaks the single-file constraint. Decide deliberately.

**Storage growth.** Four kids × several posts a day × 800 KB is small, but only because of the 7-day sweep. If the sweep silently fails, this grows forever. Set a Supabase billing alert.

**Backups.** Auto-deleting content plus point-in-time recovery are in tension — restoring a backup resurrects deleted photos. Know which you want. For this app, I'd keep PITR short.

---

## Suggested order

1. Phase 0 (consent emails out — they'll take days to come back)
2. Phases 1–4 (Supabase, schema, RLS, storage) — test RLS with impersonation before moving on
3. Phase 5 (auth) — the trickiest part
4. Phase 6 (port the front end)
5. Phase 7 (sweep) — do not launch without it
6. Phases 8–9
7. Phase 10, then hand it over

Phases 1–4 are one focused evening. Phase 6 is the longest.

---

*Supabase's dashboard and defaults change fairly often — check current docs for anything that doesn't match, particularly the cron and edge function invocation syntax.*
