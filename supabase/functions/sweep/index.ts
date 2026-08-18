// kidstogram — sweep edge function
//
// The 7-day delete and the 72-hour purge (launch plan Phase 7, plus soft
// delete from migration 0007). Two kinds of posts get purged, counted
// separately in the logs and the response:
//   expired — expires_at < now(): the normal 7-day fade-away
//   binned  — deleted_at more than 72 hours ago: the Delete button only
//             soft-deletes; the three-day gap is deliberate, so a
//             grown-up can investigate an incident before the evidence
//             disappears (see CLAUDE.md — do not shorten it here)
// A post that is both is counted once, as expired.
//
// Each batch removes the storage files FIRST, then deletes those exact
// rows by id. If a row delete fails, its files are already gone and the
// row is retried next hour (re-removing a missing file is a harmless
// no-op); rows deleted before files would orphan the files forever.
//
// It also keeps the weekly donkey rounds minted: this week's and next
// week's game_rounds rows are inserted with a random seed. Inserted,
// never overwritten — the donkey must not move mid-week — and next
// week's is minted early so there is no gap at the weekly rollover.
//
// Called hourly by pg_cron (scripts/schedule-sweep.sql) with the service
// role key as the bearer token. Anything else — including a member's own
// JWT, which would pass the platform's JWT check — is turned away.

import { createClient } from "npm:@supabase/supabase-js@2";

const WEEK_MS = 7 * 24 * 60 * 60 * 1000; // same week numbering as the client
const PURGE_MS = 72 * 60 * 60 * 1000;    // how long a binned post is kept

type Doomed = { id: string; storage_path: string | null };

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// files first, then exactly those rows, in batches of 100
async function purgeBatch(
  admin: ReturnType<typeof createClient>,
  rows: Doomed[],
  label: string,
) {
  let files = 0, deleted = 0;
  for (let i = 0; i < rows.length; i += 100) {
    const chunk = rows.slice(i, i + 100);
    const paths = chunk.map((r) => r.storage_path).filter((p): p is string => !!p);
    if (paths.length) {
      const { data: removed, error: rmErr } = await admin.storage
        .from("media")
        .remove(paths);
      if (rmErr) {
        console.error(`sweep: ${label} storage remove failed after ${files} files`, rmErr);
        return { files, deleted, failed: true };
      }
      files += removed?.length ?? 0;
    }
    const { count, error: delErr } = await admin
      .from("posts")
      .delete({ count: "exact" })
      .in("id", chunk.map((r) => r.id));
    if (delErr) {
      console.error(`sweep: ${label} row delete failed after ${deleted} rows`, delErr);
      return { files, deleted, failed: true };
    }
    deleted += count ?? 0;
  }
  return { files, deleted, failed: false };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("Authorization") !== `Bearer ${serviceKey}`) {
    return json({ error: "not_allowed" }, 401);
  }

  const admin = createClient(url, serviceKey);
  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const binnedBefore = new Date(now - PURGE_MS).toISOString();

  const { data: expiredRows, error: e1 } = await admin
    .from("posts")
    .select("id, storage_path")
    .lt("expires_at", nowIso);
  if (e1) {
    console.error("sweep: expired select failed", e1);
    return json({ error: "select_failed" }, 500);
  }

  // binned long enough ago AND not yet expired — the gte keeps the two
  // lists, and therefore the two counts, disjoint
  const { data: binnedRows, error: e2 } = await admin
    .from("posts")
    .select("id, storage_path")
    .lt("deleted_at", binnedBefore)
    .gte("expires_at", nowIso);
  if (e2) {
    console.error("sweep: binned select failed", e2);
    return json({ error: "select_failed" }, 500);
  }

  const expired = await purgeBatch(admin, (expiredRows ?? []) as Doomed[], "expired");
  const binned = await purgeBatch(admin, (binnedRows ?? []) as Doomed[], "binned");

  // ---- keep the donkey rounds minted (this week and next) ----
  const week = Math.floor(now / WEEK_MS);
  const rounds = [week, week + 1].map((w) => ({
    game_key: "donkey",
    round_key: String(w),
    seed: crypto.getRandomValues(new Uint32Array(1))[0],
    opens_at: new Date(w * WEEK_MS).toISOString(),
    closes_at: new Date((w + 1) * WEEK_MS).toISOString(),
  }));
  const { data: minted, error: roundErr } = await admin
    .from("game_rounds")
    .upsert(rounds, { onConflict: "game_key,round_key", ignoreDuplicates: true })
    .select("round_key");
  if (roundErr) console.error("sweep: round minting failed", roundErr);
  const roundsMinted = minted?.length ?? 0;

  console.log(
    `sweep: expired ${expired.deleted} posts (${expired.files} files), ` +
      `binned ${binned.deleted} posts (${binned.files} files), ` +
      `minted ${roundsMinted} round(s)`,
  );
  const failed = expired.failed || binned.failed;
  return json({
    expired: { files_removed: expired.files, rows_deleted: expired.deleted },
    binned: { files_removed: binned.files, rows_deleted: binned.deleted },
    rounds_minted: roundsMinted,
  }, failed ? 500 : 200);
});
