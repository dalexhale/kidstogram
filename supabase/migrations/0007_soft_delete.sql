-- kidstogram — 0007_soft_delete.sql
-- The Delete button becomes a soft delete with a 72-hour purge.
--
-- Binning a post sets deleted_at; the post vanishes from every wall at
-- once (select policy below), and the sweep purges the file and the row
-- 72 hours later. The gap is deliberate: it lets a grown-up investigate
-- an incident before the evidence disappears. From a child's point of
-- view nothing changes — the post is gone.

alter table posts add column deleted_at timestamptz;   -- null = not deleted
create index on posts (deleted_at);

-- Nobody sees a binned post in the app, the owner included —
-- investigation happens in the dashboard with the service role.
drop policy "members read posts" on posts;
create policy "members read posts" on posts
  for select using (is_member() and expires_at > now() and deleted_at is null);

-- The Delete button is now an UPDATE of deleted_at — and of nothing
-- else: posts moves to column-level update grants (the 0003 profiles
-- pattern), so this policy cannot be used to edit a post's content.
revoke update on posts from authenticated, anon;
grant update (deleted_at) on posts to authenticated;

create policy "bin own posts, owner bins any" on posts
  for update using (is_member() and (author_id = auth.uid() or is_owner()))
  with check (
    is_member() and (author_id = auth.uid() or is_owner())
    and (
      -- binning: the timestamp must be "now", give or take tablet clock
      -- skew. A backdated deleted_at would jump the 72-hour queue and
      -- purge on the next sweep — exactly the hole this window closes.
      deleted_at between now() - interval '10 minutes' and now() + interval '10 minutes'
      -- restoring (back to null) is the owner's call only, so an author
      -- cannot un-bin their own post mid-investigation
      or (deleted_at is null and is_owner())
    )
  );

-- The client no longer hard-deletes anything. Without this drop, an
-- author could still remove the row (cascading stamps and comments)
-- through the API and skip the 72-hour window entirely. The sweep's
-- service role bypasses RLS, so the purge is unaffected.
drop policy "delete own posts, owner deletes any" on posts;

-- Same hole on the file side: the old storage delete policy let an
-- author remove their file directly, destroying the evidence while the
-- row lingered. The one client path that still needs a storage delete is
-- dbStickIt's cleanup when its posts INSERT fails — a file that no posts
-- row references. So: your own folder, orphaned files only.
-- (security definer, because the caller's posts select policy hides
-- soft-deleted rows — exactly the rows this check must be able to see)
create or replace function is_orphan_media(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from posts where storage_path = object_name);
$$;

revoke execute on function is_orphan_media(text) from public, anon;
grant execute on function is_orphan_media(text) to authenticated;

drop policy "delete your own, owner deletes any" on storage.objects;
create policy "tidy your own orphaned uploads" on storage.objects
  for delete using (
    bucket_id = 'media'
    and is_member()
    and (storage.foldername(name))[1] = auth.uid()::text
    and is_orphan_media(name)
  );
