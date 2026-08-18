-- kidstogram — 0004_seen_walkthrough.sql
-- Libby's rule: the 7-page how-it-works walkthrough shows only the first
-- time a person uses the app. The no-bullying screen still shows every
-- single time — that one is never skipped.
--
-- The client reads this at page load to decide walkthrough vs no-bullying,
-- and sets it to true itself when the last page is finished: profiles has
-- no client INSERT policy, but "you edit your own profile" (update, own
-- row) covers this write.
--
-- 0003 moved profiles to column-level grants, so the new column must be
-- added to the select grant or members cannot read it back.

alter table profiles add column seen_walkthrough boolean not null default false;
grant select (seen_walkthrough) on profiles to authenticated;
