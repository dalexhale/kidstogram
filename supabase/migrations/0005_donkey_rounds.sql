-- kidstogram — 0005_donkey_rounds.sql
-- Pin the Tail stops inventing its weekly round on the client.
--
-- Until now the client derived the seed from the date, which means anyone
-- could compute where the donkey will be — this week or any future week.
-- The seed is now a random number in game_rounds (0001 already made the
-- table), minted server-side by the sweep edge function. This file mints
-- the first two rounds so the game works before the cron job exists.
--
-- current_round() is how the client asks "which round is open right now?"
-- using the SERVER's clock — a tablet with a wonky clock near the weekly
-- rollover must not read, or score into, the wrong round. It is security
-- invoker, so the "members read rounds" policy still decides who may see
-- a seed at all.

create or replace function current_round(game text)
returns table (round_key text, seed bigint)
language sql stable as $$
  select r.round_key, r.seed
  from game_rounds r
  where r.game_key = game
    and now() >= r.opens_at and now() < r.closes_at
  order by r.opens_at desc
  limit 1;
$$;

revoke execute on function current_round(text) from public, anon;
grant execute on function current_round(text) to authenticated;

-- The client sends its measured distance (in detail) and the points for
-- it; this ties the two together so a hand-rolled insert cannot claim
-- 1000 points alongside a mile-wide miss. The distance itself is still
-- the client's own measurement — the stage geometry lives in the browser
-- — so the real teeth are the one-go unique constraint and the round
-- window in the 0001 insert policy. round() goes through numeric because
-- round(float8) rounds halves to even, while the client's Math.round
-- rounds them up.
alter table game_scores add constraint donkey_points_match_dist check (
  game_key <> 'donkey'
  or (
    (detail->>'dist') is not null
    and (detail->>'dist')::float8 between 0 and 4
    and points = greatest(0, round((1000 - (detail->>'dist')::float8 * 420)::numeric))::int
  )
);

-- Mint this week's and next week's rounds so the game works right away.
-- Weeks are floor(epoch / 7 days) — the same numbering as the sweep
-- function. on conflict do nothing: an existing seed is NEVER replaced,
-- because the donkey must not move mid-week.
insert into game_rounds (game_key, round_key, seed, opens_at, closes_at)
select 'donkey',
       w::text,
       floor(random() * 4294967296)::bigint,
       to_timestamp(w * 604800),
       to_timestamp((w + 1) * 604800)
from generate_series(
       floor(extract(epoch from now()) / 604800)::bigint,
       floor(extract(epoch from now()) / 604800)::bigint + 1
     ) as w
on conflict (game_key, round_key) do nothing;
