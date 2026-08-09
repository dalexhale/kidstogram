# kidstogram

A private photo wall for Libby and three friends. Front end by Libby, plumbing by Dale.

- `index.html` — the working front end (fake data, no backend yet)
- `CLAUDE.md` — project context and rules; read this first
- `docs/launch-plan.md` — the phased build plan for the Supabase backend

## Running it

Open `index.html` in a browser. That's it, for now.

The camera needs HTTPS or localhost — it will silently fail on a `file://` URL.
Use `npx serve .` and open the localhost address.

## Deploying

GitHub → Vercel, framework preset "Other". No build step yet.
