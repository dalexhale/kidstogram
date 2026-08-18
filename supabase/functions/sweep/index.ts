// kidstogram — sweep edge function
//
// The 7-day delete (launch plan Phase 7). Deleting a posts row does NOT
// delete its file in Storage, so this does both, files first:
//   1. find posts where expires_at < now()
//   2. remove their files from the private `media` bucket
//   3. delete the rows (stamps and comments go with them, on delete cascade)
// If a storage delete fails, the rows are LEFT ALONE and the run aborts:
// an expired row with a file is retried next hour, but a file with no row
// would be orphaned forever.
//
// It also keeps the weekly donkey rounds minted: this week's and next
// week's game_rounds rows are inserted with a random seed. Inserted, never
// overwritten — the donkey must not move mid-week — and next week's is
// minted early so there is no gap at the weekly rollover.
//
// Called hourly by pg_cron (scripts/schedule-sweep.sql) with the service
// role key as the bearer token. Anything else — including a member's own
// JWT, which would pass the platform's JWT check — is turned away.

import { createClient } from "npm:@supabase/supabase-js@2";

const WEEK_MS = 7 * 24 * 60 * 60 * 1000; // same week numbering as the client

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("Authorization") !== `Bearer ${serviceKey}`) {
    return json({ error: "not_allowed" }, 401);
  }

  const admin = createClient(url, serviceKey);

  // One cutoff for both steps. A post that expires between the select and
  // the delete waits for the next run — deleting rows with a fresh now()
  // would orphan any file that expired in between.
  const cutoff = new Date().toISOString();

  const { data: expired, error: selErr } = await admin
    .from("posts")
    .select("id, storage_path")
    .lt("expires_at", cutoff);
  if (selErr) {
    console.error("sweep: select failed", selErr);
    return json({ error: "select_failed" }, 500);
  }

  const paths = (expired ?? [])
    .map((r) => r.storage_path)
    .filter((p): p is string => !!p); // made-up pictures have no file

  let filesRemoved = 0;
  for (let i = 0; i < paths.length; i += 100) {
    const chunk = paths.slice(i, i + 100);
    const { data: removed, error: rmErr } = await admin.storage
      .from("media")
      .remove(chunk);
    if (rmErr) {
      console.error(`sweep: storage remove failed after ${filesRemoved} files`, rmErr);
      return json({ error: "storage_remove_failed", files_removed: filesRemoved }, 500);
    }
    filesRemoved += removed?.length ?? 0;
  }

  const { count, error: delErr } = await admin
    .from("posts")
    .delete({ count: "exact" })
    .lt("expires_at", cutoff);
  if (delErr) {
    console.error("sweep: row delete failed", delErr);
    return json({ error: "delete_failed", files_removed: filesRemoved }, 500);
  }
  const rowsDeleted = count ?? 0;

  // ---- keep the donkey rounds minted (this week and next) ----
  const week = Math.floor(Date.now() / WEEK_MS);
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
    `sweep: removed ${filesRemoved} storage files, deleted ${rowsDeleted} expired posts, minted ${roundsMinted} round(s)`,
  );
  return json({
    files_removed: filesRemoved,
    rows_deleted: rowsDeleted,
    rounds_minted: roundsMinted,
  });
});
