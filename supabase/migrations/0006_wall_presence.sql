-- kidstogram — 0006_wall_presence.sql
-- Real presence for the online dots.
--
-- The client joins a PRIVATE Realtime channel called 'wall'. Realtime
-- authorises private channels against policies on realtime.messages —
-- deny-by-default, like everything else here. A public channel would let
-- anyone holding the anon key (it ships in the page) watch which children
-- are online and harvest their usernames; private-plus-policies keeps
-- that to signed-in, unsuspended members.
--
-- select = may listen to presence on the topic; insert = may share their
-- own. One topic, presence only — no broadcast policies, so no other use
-- of Realtime sneaks in with it.

create policy "members read wall presence" on realtime.messages
  for select to authenticated
  using (
    realtime.topic() = 'wall'
    and extension = 'presence'
    and public.is_member()
  );

create policy "members share wall presence" on realtime.messages
  for insert to authenticated
  with check (
    realtime.topic() = 'wall'
    and extension = 'presence'
    and public.is_member()
  );
