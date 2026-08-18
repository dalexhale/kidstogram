-- kidstogram — 0003_pin_privacy.sql
-- Members could read each other's pin_hash through the "members see each
-- other" select policy. The row policy stays — it still decides which ROWS
-- you can see — but column-level grants now decide which COLUMNS:
-- everyone's username / real_name / is_owner / suspended, nobody's
-- pin_hash (and, as a bonus, nobody's parent_email).
--
-- Your own hash comes back through my_pin_hash() instead, which runs as
-- the table owner and only ever looks at the caller's own row. It exists
-- purely for the client-side device unlock; nothing server-side may
-- depend on it.

revoke select on profiles from authenticated, anon;
grant select (id, username, real_name, is_owner, suspended)
  on profiles to authenticated;

create or replace function my_pin_hash() returns text
language sql stable security definer set search_path = public as $$
  select pin_hash from profiles where id = auth.uid();
$$;

revoke execute on function my_pin_hash() from public, anon;
grant execute on function my_pin_hash() to authenticated;
