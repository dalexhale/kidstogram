-- kidstogram — seed.sql
--
-- >>> REPLACE every placeholder email below with the real parent's address —
-- >>> the Google account that parent will actually sign in with (Phase 5.1).
-- >>> Check the child names too. Run this AFTER 0001_init.sql.
--
-- Exactly one row has is_owner = true: Dale's, which makes libby.r the
-- owner account with the kick-out button.

insert into allowlist (parent_email, child_name, is_owner) values
  ('cwaitzberg@gmail.com',    'Libby Rabinowitz', true),
  ('markhickson86@gmail.com','Rosie Hickson',  false),
  ('nissen2004@gmail.com','Maya Lewis',  false),
  ('steinbergerfam@gmail.com','Maya Steinberger',  false);
