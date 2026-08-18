// kidstogram — check-allowlist edge function
//
// The only gate into the app, and the only path that can create a profile
// (profiles has no client INSERT policy on purpose).
//
// Two modes, both POST, both requiring a signed-in caller:
//   { mode: "check" }
//     -> { allowed: false }
//     -> { allowed: true, is_owner, child_name, has_profile, suspended }
//   { mode: "create-profile", username, real_name, pin_hash }
//     -> { ok: true, username, real_name, is_owner }
//     -> { ok: false, error: "not_allowed" | "bad_input" | "already_has_profile" | "username_taken" }
//
// The caller's identity comes from their JWT, never from the request body.
// The allowlist is read — and the profile row inserted — with the service
// role key, which exists only in this function's environment. Expected
// outcomes are returned as 200s so the browser client can branch on the
// body; non-200s are reserved for malformed or unauthenticated requests.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// shape of a bcrypt hash, e.g. $2a$10$<22 char salt><31 char hash>
const BCRYPT_RE = /^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Who is calling? Resolved from their JWT.
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user }, error: userErr } = await asCaller.auth.getUser();
  if (userErr || !user?.email) return json({ error: "not_signed_in" }, 401);

  let body: {
    mode?: string;
    username?: string;
    real_name?: string;
    pin_hash?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const admin = createClient(url, serviceKey);

  const { data: allowRow, error: alErr } = await admin
    .from("allowlist")
    .select("parent_email, child_name, is_owner")
    .eq("parent_email", user.email)
    .maybeSingle();
  if (alErr) return json({ error: "server_error" }, 500);

  if (body.mode === "check") {
    if (!allowRow) return json({ allowed: false });
    const { data: prof, error: pErr } = await admin
      .from("profiles")
      .select("id, suspended")
      .eq("id", user.id)
      .maybeSingle();
    if (pErr) return json({ error: "server_error" }, 500);
    return json({
      allowed: true,
      is_owner: allowRow.is_owner,
      child_name: allowRow.child_name,
      has_profile: prof !== null,
      suspended: prof?.suspended ?? false,
    });
  }

  if (body.mode === "create-profile") {
    // verify the allowlist again — never trust that "check" already ran
    if (!allowRow) return json({ ok: false, error: "not_allowed" });

    const username = String(body.username ?? "").trim().toLowerCase();
    const realName = String(body.real_name ?? "").trim();
    const pinHash = String(body.pin_hash ?? "");
    if (
      username.length < 3 || username.length > 18 ||
      realName.length < 2 || realName.length > 16 ||
      !BCRYPT_RE.test(pinHash)
    ) {
      return json({ ok: false, error: "bad_input" });
    }

    const { data: existing, error: exErr } = await admin
      .from("profiles")
      .select("id")
      .eq("id", user.id)
      .maybeSingle();
    if (exErr) return json({ error: "server_error" }, 500);
    if (existing) return json({ ok: false, error: "already_has_profile" });

    const { error: insErr } = await admin.from("profiles").insert({
      id: user.id,
      username,
      real_name: realName,
      parent_email: allowRow.parent_email,
      is_owner: allowRow.is_owner,
      pin_hash: pinHash,
    });
    if (insErr) {
      // 23505 = unique violation: two kids tapped at the same moment
      if (insErr.code === "23505") {
        return json({ ok: false, error: "username_taken" });
      }
      return json({ error: "server_error" }, 500);
    }

    return json({
      ok: true,
      username,
      real_name: realName,
      is_owner: allowRow.is_owner,
    });
  }

  return json({ error: "bad_mode" }, 400);
});
