-- Run once, by the db image, when it creates a new cluster (an empty pg-data
-- volume): as the `postgres` superuser, through the Unix socket.
--
-- Odoo refuses to run with a superuser role, as superusers can run OS commands
-- and read or write files in the db container. So:
-- - `odoo` is a regular role that can create databases, used by Odoo and psql
--   in the dev container;
-- - `postgres`, the superuser, has no password: it's only reachable through
--   the socket, from inside the db container.

ALTER ROLE postgres PASSWORD NULL;
CREATE ROLE odoo LOGIN CREATEDB PASSWORD 'odoo';

-- Only a superuser can create untrusted extensions, such as `vector` (AI
-- modules). Create it in the template Odoo creates databases from (db_template,
-- template0 by default), so that they all have it, as Odoo's own warning
-- suggests. template0 normally refuses connections: allow them just for that.
ALTER DATABASE template0 ALLOW_CONNECTIONS true;
\connect template0
CREATE EXTENSION vector WITH SCHEMA public;
\connect postgres
ALTER DATABASE template0 ALLOW_CONNECTIONS false;
