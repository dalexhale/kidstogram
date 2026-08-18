-- kidstogram — scripts/test-rls.sql
--
-- RLS smoke test. Paste the whole file into the Supabase SQL editor and run it
-- once, top to bottom. It impersonates three personas with
-- `set local role authenticated` + `set local request.jwt.claims`:
--
--   member      — active profile, suspended = false  → should see rows
--   suspended   — profile with suspended = true      → should see nothing
--   non-member  — valid auth user, no profile row    → should see nothing
--
-- Each persona attempts to read profiles, posts and comments. The storage
-- policies are tested WITHOUT touching storage.objects (Supabase's
-- storage.protect_delete() trigger forbids direct SQL deletes there):
-- instead the policy predicates are evaluated directly under each JWT —
-- is_member() for the read policy, and the folder-ownership condition
-- `(storage.foldername(name))[1] = auth.uid()::text` against synthetic
-- paths for the upload policy. Aside from the literal `bucket_id = 'media'`
-- comparison, those predicates ARE the storage policies, so this is
-- equivalent to row-level behaviour.
--
-- The final (and only visible) result set lists all 16 checks with PASS/FAIL
-- and a SUMMARY row at the bottom. Expected outcome: 16 × PASS, ALL PASS.
-- Cleanup steps are individually wrapped so a failure in one can't abort the
-- run; any that do fail appear as CLEANUP rows in the report.
--
-- Self-contained:
--   * Creates its own fixture rows (fake auth.users, allowlist entries,
--     profiles, a post, a comment) under fixed test UUIDs and
--     rls-test-*@example.com emails, and deletes them all at the end.
--     Real users get random UUIDs from GoTrue, so the fixed IDs can't collide.
--   * Pre-cleans leftovers from a previous aborted run, so it's safe to re-run.
--
-- Requirements: 0001_init.sql already applied; run as `postgres` (the SQL
-- editor default), which owns the public tables and so isn't blocked by the
-- very policies under test when writing fixtures.
--
-- Fixture IDs:
--   member     11111111-1111-4111-8111-111111111111
--   suspended  22222222-2222-4222-8222-222222222222
--   non-member 33333333-3333-4333-8333-333333333333
--   post       44444444-4444-4444-8444-444444444444
--   comment    55555555-5555-4555-8555-555555555555

-- ============================================================
-- 0. Scratch tables + pre-clean (idempotent)
-- ============================================================

drop table if exists pg_temp.rls_results;
drop table if exists pg_temp.rls_cleanup_errors;
drop table if exists pg_temp.rls_state;   -- leftover from an older version of this script

create temp table rls_results (
  check_no int primary key,
  persona  text not null,
  subject  text not null,
  expected text not null check (expected in ('rows', 'none', 'true', 'false')),
  got      text not null
);

create temp table rls_cleanup_errors (
  step text not null,
  err  text not null
);

-- the persona transactions run as `authenticated`, which must be able to
-- record its results here
grant insert on table pg_temp.rls_results to authenticated;

-- leftovers from a previous run that died halfway
delete from auth.users        -- cascades: profiles → posts → comments
 where id in ('11111111-1111-4111-8111-111111111111',
              '22222222-2222-4222-8222-222222222222',
              '33333333-3333-4333-8333-333333333333');
delete from public.allowlist
 where parent_email in ('rls-test-member@example.com',
                        'rls-test-suspended@example.com');

-- ============================================================
-- 1. Fixtures (public + auth tables only; storage is never written)
-- ============================================================

-- three fake auth users; empty-string tokens keep GoTrue happy if cleanup
-- ever fails and these rows linger
insert into auth.users
  (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
   raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
   confirmation_token, recovery_token, email_change_token_new, email_change)
values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111',
   'authenticated', 'authenticated', 'rls-test-member@example.com',    '', now(), '{}', '{}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222',
   'authenticated', 'authenticated', 'rls-test-suspended@example.com', '', now(), '{}', '{}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-4333-8333-333333333333',
   'authenticated', 'authenticated', 'rls-test-outsider@example.com',  '', now(), '{}', '{}', now(), now(), '', '', '', '');

-- allowlist + profiles for the two personas that have one; the non-member
-- deliberately gets neither
insert into public.allowlist (parent_email, child_name, is_owner) values
  ('rls-test-member@example.com',    'RLS Member',    false),
  ('rls-test-suspended@example.com', 'RLS Suspended', false);

insert into public.profiles (id, username, real_name, parent_email, is_owner, suspended) values
  ('11111111-1111-4111-8111-111111111111', 'rls.tester.one', 'RLS Member',    'rls-test-member@example.com',    false, false),
  ('22222222-2222-4222-8222-222222222222', 'rls.tester.two', 'RLS Suspended', 'rls-test-suspended@example.com', false, true);

-- one post (made_up, so no storage dependency) and one comment
insert into public.posts (id, author_id, kind, drawn_key, bg_key) values
  ('44444444-4444-4444-8444-444444444444', '11111111-1111-4111-8111-111111111111', 'made_up', 'cat', 'space');

insert into public.comments (id, post_id, author_id, body) values
  ('55555555-5555-4555-8555-555555555555', '44444444-4444-4444-8444-444444444444',
   '11111111-1111-4111-8111-111111111111', 'rls test comment');

-- ============================================================
-- 2. Persona: active member — sees rows, storage predicates true
--    (positive table checks target the fixture rows specifically, so they
--    can't pass off the back of unrelated real data)
--
--    Predicates are coalesced to false because RLS treats a null predicate
--    as a denial — coalesce mirrors that.
-- ============================================================

begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';

insert into rls_results (check_no, persona, subject, expected, got) values
  (1, 'member', 'profiles', 'rows',
     (select count(*) from public.profiles where id = '11111111-1111-4111-8111-111111111111')::text),
  (2, 'member', 'posts', 'rows',
     (select count(*) from public.posts    where id = '44444444-4444-4444-8444-444444444444')::text),
  (3, 'member', 'comments', 'rows',
     (select count(*) from public.comments where id = '55555555-5555-4555-8555-555555555555')::text),
  (4, 'member', 'storage read policy (is_member)', 'true',
     coalesce(is_member(), false)::text),
  (5, 'member', 'storage upload policy (own folder)', 'true',
     coalesce(is_member()
              and (storage.foldername('11111111-1111-4111-8111-111111111111/rls-test.jpg'))[1] = auth.uid()::text
            , false)::text),
  (6, 'member', 'storage upload policy (other''s folder)', 'false',
     coalesce(is_member()
              and (storage.foldername('22222222-2222-4222-8222-222222222222/rls-test.jpg'))[1] = auth.uid()::text
            , false)::text);
commit;

-- ============================================================
-- 3. Persona: suspended member — zero rows, storage predicates false
--    (unfiltered counts: nothing at all should be visible, not even their
--    own profile)
-- ============================================================

begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';

insert into rls_results (check_no, persona, subject, expected, got) values
  ( 7, 'suspended', 'profiles', 'none', (select count(*) from public.profiles)::text),
  ( 8, 'suspended', 'posts',    'none', (select count(*) from public.posts)::text),
  ( 9, 'suspended', 'comments', 'none', (select count(*) from public.comments)::text),
  (10, 'suspended', 'storage read policy (is_member)', 'false',
     coalesce(is_member(), false)::text),
  (11, 'suspended', 'storage upload policy (own folder)', 'false',
     coalesce(is_member()
              and (storage.foldername('22222222-2222-4222-8222-222222222222/rls-test.jpg'))[1] = auth.uid()::text
            , false)::text);
commit;

-- ============================================================
-- 4. Persona: authenticated non-member — zero rows, storage predicates false
-- ============================================================

begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';

insert into rls_results (check_no, persona, subject, expected, got) values
  (12, 'non-member', 'profiles', 'none', (select count(*) from public.profiles)::text),
  (13, 'non-member', 'posts',    'none', (select count(*) from public.posts)::text),
  (14, 'non-member', 'comments', 'none', (select count(*) from public.comments)::text),
  (15, 'non-member', 'storage read policy (is_member)', 'false',
     coalesce(is_member(), false)::text),
  (16, 'non-member', 'storage upload policy (own folder)', 'false',
     coalesce(is_member()
              and (storage.foldername('33333333-3333-4333-8333-333333333333/rls-test.jpg'))[1] = auth.uid()::text
            , false)::text);
commit;

-- ============================================================
-- 5. Cleanup (back on the postgres role)
--    Each step swallows its own errors so the report below always prints;
--    failures surface as CLEANUP rows in the report instead.
-- ============================================================

do $$
begin
  delete from auth.users        -- cascades: profiles → posts → comments
   where id in ('11111111-1111-4111-8111-111111111111',
                '22222222-2222-4222-8222-222222222222',
                '33333333-3333-4333-8333-333333333333');
exception when others then
  insert into rls_cleanup_errors values ('delete test auth.users', sqlerrm);
end $$;

do $$
begin
  delete from public.allowlist
   where parent_email in ('rls-test-member@example.com',
                          'rls-test-suspended@example.com');
exception when others then
  insert into rls_cleanup_errors values ('delete test allowlist rows', sqlerrm);
end $$;

-- ============================================================
-- 6. Report — the last statement is the one the SQL editor displays
-- ============================================================

with graded as (
  select check_no, persona, subject, expected, got,
         case expected
           when 'rows' then got::bigint > 0
           when 'none' then got::bigint = 0
           else got = expected
         end as pass
  from rls_results
)
select lpad(check_no::text, 2, '0') || '. ' || persona || ' — ' || subject as check_name,
       case expected
         when 'rows' then 'rows visible'
         when 'none' then 'no rows'
         else expected
       end                                                                 as expected,
       case when expected in ('rows', 'none') then got || ' row(s)' else got end as returned,
       case when pass then 'PASS' else 'FAIL' end                          as result
from graded
union all
select 'CLEANUP failed: ' || step, 'clean removal', err, 'FAIL'
from rls_cleanup_errors
union all
select 'SUMMARY',
       count(*)::text || ' checks',
       (count(*) filter (where pass))::text     || ' passed, ' ||
       (count(*) filter (where not pass))::text || ' failed',
       case when bool_and(pass) then 'ALL PASS'
            else 'FAIL: ' || string_agg(persona || ' — ' || subject, '; ' order by check_no)
                             filter (where not pass)
       end
from graded
order by 1;   -- '01.'–'16.' first, then any 'CLEANUP…' rows, 'SUMMARY' last
