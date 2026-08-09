# kidstogram

A private photo-sharing app for four 8-year-old girls. Not a public product. Not a startup.
The users are Libby and three named friends, and their parents.

`docs/launch-plan.md` is the authoritative build plan. Read it before touching backend code.

---

## Who decides what

**Libby (8) is the design lead.** Colours, layout, wording, features, game rules — hers.
**Dale is the technical lead.** Architecture, security, deployment, data — his.

### The rule that matters most

**Do not add features, buttons, links, hints, or UI elements that were not explicitly asked for.**

This is not a stylistic preference. It has been raised directly and more than once. A "helpful"
skip button and a help link were both added unasked and both had to be removed. If something
seems obviously missing, say so and ask. Do not build it and apologise afterwards.

The same applies to removing things. Libby's deliberate design choices sometimes make the app
harder — no hints in Piñata Smash, no skip on the walkthrough. Those are decisions, not oversights.

### How to talk to each of them

Libby: short sentences, plain words, no jargon. Be honest when something won't work or is a
bad idea, and explain why in terms she can act on. She is a genuinely good tester and catches
real bugs — take her reports seriously and investigate rather than assuming she misused it.

Dale: technical, direct, no padding.

---

## What the app does

Closed wall. Four members. Everyone sees everything anyone posts. No private messaging.

- **Posts** — a selfie, a short video with sound, a scanned paper drawing, or a built-in
  hand-drawn picture. Composited over a scenery backdrop (library, space, beach, and 7 more)
  or a plain colour, with up to 3 animated overlay filters.
- **Two ways a photo meets its backdrop** — `stick` (shrinks with a white print edge) or
  `jump` (soft oval mask so the subject appears inside the scene). `jump` is a feathered
  ellipse, **not** real segmentation. This limitation is known and accepted; do not silently
  swap in a segmentation library.
- **Everything expires after 7 days**, fading visibly as it ages, then drifting off screen.
- **Stamps** — 17 hand-drawn stickers, draggable after placement. You can move your own;
  the owner can move anyone's.
- **Comments** — 32 tappable preset phrases (max 4 words each) plus free typing. Author
  name always shown. No edit, only delete.
- **Games** — Noughts and Crosses, Connect 4 (both hot-seat, two-player), and Pin the Tail
  on the Donkey (weekly seeded round, one go each, leaderboard).
- **Onboarding** — a 7-page how-it-works walkthrough, then a no-bullying screen, then login.
  All three are compulsory every session. That is deliberate.
- **Moderation** — a kick-out button visible only to the owner account (`libby.r`).

---

## Design language

Hand-drawn, wobbly, like a scrapbook. Not flat vector. Not emoji-as-art (emoji are used
sparingly in text, never as illustration).

```
--sugar #FAE6F1   --sugar-bottom #E6E0F5   --lilac #C9A6E8
--ink   #2F3A3E   --pencil #5A6B70         --print #FBF8F1
--pink  #E8688F   --blue #4B8FD4           --grape #8E6FC4
--green #7FCB9B   --orange #F08A4B         --tape #F0C64E   --red #E04B3C
```

- **Fonts** — `Patrick Hand` for everything, `Rubik Bubbles` for display. Comic Sans fallback.
- **Texture** — SVG `feTurbulence` + `feDisplacementMap` filters (`#crayon`, `#crayon2`) give
  the wobbly crayon edge. Use them on new artwork.
- **Wobble** — border radii are deliberately uneven (`22px 19px 23px 20px`), elements sit at
  slight rotations. Keep this up in new UI.
- **Buttons** — thick ink border, hard offset shadow, press-down on `:active`.

---

## Technical rules

**Touch is the primary input.** Every interactive element needs both touch events and a
mouse/click path. Pointer events alone have caused real bugs on this project more than once.
Use the existing `onTap(el, fn)` helper — it handles the touchend/click double-fire.

**Never trust the client.** Scores, expiry, membership and moderation are all enforced
server-side. The client is a rendering layer.

**Security invariants — do not change these without Dale:**
- Storage bucket is **private**. Access via signed URLs only.
- Every table is RLS deny-by-default.
- The service role key never appears in client code, Vercel env, or the bundle.
- The allowlist check runs in an edge function, never in the browser.
- Images go through `canvas.drawImage()` + re-encode before upload. **This is what strips
  EXIF/GPS.** Never upload a raw `File` from the picker as an "optimisation".
- Comments have no UPDATE policy on purpose — they cannot be silently edited after posting.

**The 9-digit PIN is not a credential.** It is a device unlock on top of an authenticated
Google session. Do not let it gate anything server-side. Do not remove it either — it is
Libby's design and she is attached to it.

---

## Current state

`index.html` is a complete, working front end running entirely on fake in-memory data.
Every screen and interaction listed above is built and functional. There is no backend yet.

Porting it means replacing the in-memory `posts`, `friends`, `realNames` and `online`
variables with Supabase queries, and swapping data-URL images for signed URLs. The UI
should not need redesigning.

### Not yet built
- All backend (see `docs/launch-plan.md`)
- Musical Chairs and Piñata Smash (the other two party games) — **not yet approved for port**
- Real presence for the online dots (currently a hardcoded pretend set)
- Cross-device play for the two-player games (currently hot-seat only)

### Known open questions
- Whether the login screen should list which usernames are already taken
- Whether GIRL PWR should also exist as a stamp

---

## Working practice

- Verify game logic and anything with edge cases with a Node script before saying it works.
  Win detection, seeded rounds and scoring have all been tested this way.
- When Libby reports a bug, reproduce it before theorising. A screen recording she sent
  revealed a CSS flex bug that had been misdiagnosed twice from description alone.
- Prefer small diffs. This file was a monolith for a long time; keep new work modular.
- British English throughout ("colour", "favourite").
