-- kidstogram — 0002_pin_hash.sql
-- Adds the device-unlock PIN hash to profiles (launch plan 5.3).
--
-- The PIN is NOT a credential. The bcrypt hash is written once by the
-- check-allowlist edge function when the profile is created, and is only
-- ever verified client-side. Nothing server-side — no policy, no
-- function — may depend on it.

alter table profiles add column pin_hash text
  check (pin_hash is null or pin_hash ~ '^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$');
