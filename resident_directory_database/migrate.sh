#!/bin/bash
set -euo pipefail

# Resident Directory DB migrations + seed data
#
# This script is intentionally idempotent: it can be run multiple times safely.
# It uses the same connection info pattern as the rest of this container:
# - db_connection.txt contains the canonical psql connection string
#
# Tables covered:
# - users/roles (app_user, role, user_role)
# - residents
# - change requests + approvals
# - audit log
# - CSV import tracking
#
# Indexing:
# - Trigram indexes for name/unit searching
# - Normal btree indexes for common filters and joins

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${ROOT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "ERROR: ${CONN_FILE} not found. Start the database first (startup.sh creates it)."
  exit 1
fi

DATABASE_URL="$(cat "${CONN_FILE}")"

# Extract the pure postgres URL if the file contains "psql <url>" (current container does)
if [[ "${DATABASE_URL}" == psql\ * ]]; then
  DATABASE_URL="${DATABASE_URL#psql }"
fi

# Use ON_ERROR_STOP=1 to fail fast on any SQL error.
PSQL="psql \"${DATABASE_URL}\" -v ON_ERROR_STOP=1"

echo "Running resident directory migrations using connection from db_connection.txt"

# 1) Extensions for search
${PSQL} -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
${PSQL} -c "CREATE EXTENSION IF NOT EXISTS citext;"
${PSQL} -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

# 2) Utility trigger for updated_at
${PSQL} -c "
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS \$\$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
\$\$ LANGUAGE plpgsql;
"

# 3) Roles and users
${PSQL} -c "
CREATE TABLE IF NOT EXISTS role (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);
"

${PSQL} -c "
CREATE TABLE IF NOT EXISTS app_user (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext NOT NULL UNIQUE,
  password_hash text NOT NULL,
  display_name text,
  is_active boolean NOT NULL DEFAULT true,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
"

${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'tr_app_user_set_updated_at'
  ) THEN
    CREATE TRIGGER tr_app_user_set_updated_at
    BEFORE UPDATE ON app_user
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END
\$\$;
"

${PSQL} -c "
CREATE TABLE IF NOT EXISTS user_role (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  role_id uuid NOT NULL REFERENCES role(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);
"

${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_user_role_role_id ON user_role(role_id);"

# 4) Residents
${PSQL} -c "
CREATE TABLE IF NOT EXISTS resident (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Optional linkage to an authenticated user (resident account)
  user_id uuid UNIQUE REFERENCES app_user(id) ON DELETE SET NULL,

  first_name text NOT NULL,
  last_name text NOT NULL,
  unit text NOT NULL,

  phone text,
  email citext,

  -- Privacy controls (resident-managed)
  -- directory_opt_out: if true, the resident should not appear in public directory results
  directory_opt_out boolean NOT NULL DEFAULT false,
  -- field-level visibility flags (true = visible in directory; false = hidden)
  phone_visible boolean NOT NULL DEFAULT true,
  email_visible boolean NOT NULL DEFAULT true,

  is_active boolean NOT NULL DEFAULT true,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- Helpful for case-insensitive exact matching; search uses trigram indexes below
  CONSTRAINT resident_unit_nonempty CHECK (length(btrim(unit)) > 0),
  CONSTRAINT resident_first_name_nonempty CHECK (length(btrim(first_name)) > 0),
  CONSTRAINT resident_last_name_nonempty CHECK (length(btrim(last_name)) > 0)
);
"

# 4b) Resident favorites (per-user)
# A user can favorite any resident in the directory (subject to authz checks in backend).
${PSQL} -c "
CREATE TABLE IF NOT EXISTS resident_favorite (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  resident_id uuid NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, resident_id)
);
"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_favorite_user_id_created_at ON resident_favorite(user_id, created_at DESC);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_favorite_resident_id ON resident_favorite(resident_id);"

${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'tr_resident_set_updated_at'
  ) THEN
    CREATE TRIGGER tr_resident_set_updated_at
    BEFORE UPDATE ON resident
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END
\$\$;
"

# Search indexes: name, unit, and composite
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_unit ON resident(unit);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_last_first ON resident(last_name, first_name);"

# Trigram indexes for ILIKE / fuzzy matching
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_first_name_trgm ON resident USING gin (first_name gin_trgm_ops);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_last_name_trgm ON resident USING gin (last_name gin_trgm_ops);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_unit_trgm ON resident USING gin (unit gin_trgm_ops);"

# Convenience computed column for full name searches (stored generated for indexability)
${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name='resident' AND column_name='full_name'
  ) THEN
    ALTER TABLE resident
      ADD COLUMN full_name text GENERATED ALWAYS AS (btrim(first_name) || ' ' || btrim(last_name)) STORED;
  END IF;
END
\$\$;
"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_resident_full_name_trgm ON resident USING gin (full_name gin_trgm_ops);"

# Privacy columns: add if missing (for existing DBs created before these fields existed)
${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='resident' AND column_name='directory_opt_out'
  ) THEN
    ALTER TABLE resident ADD COLUMN directory_opt_out boolean NOT NULL DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='resident' AND column_name='phone_visible'
  ) THEN
    ALTER TABLE resident ADD COLUMN phone_visible boolean NOT NULL DEFAULT true;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='resident' AND column_name='email_visible'
  ) THEN
    ALTER TABLE resident ADD COLUMN email_visible boolean NOT NULL DEFAULT true;
  END IF;
END
\$\$;
"

# 5) Change requests + approvals
${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'change_request_status') THEN
    CREATE TYPE change_request_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED');
  END IF;
END
\$\$;
"

${PSQL} -c "
CREATE TABLE IF NOT EXISTS resident_change_request (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resident_id uuid NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
  requested_by_user_id uuid REFERENCES app_user(id) ON DELETE SET NULL,

  status change_request_status NOT NULL DEFAULT 'PENDING',

  -- JSON describing patch-like requested changes, e.g. {\"phone\":\"...\"}
  requested_changes jsonb NOT NULL,

  reason text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  reviewed_at timestamptz,
  reviewed_by_user_id uuid REFERENCES app_user(id) ON DELETE SET NULL,
  review_note text
);
"

${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'tr_resident_change_request_set_updated_at'
  ) THEN
    CREATE TRIGGER tr_resident_change_request_set_updated_at
    BEFORE UPDATE ON resident_change_request
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END
\$\$;
"

${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_rcr_resident_id ON resident_change_request(resident_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_rcr_status_created_at ON resident_change_request(status, created_at DESC);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_rcr_requested_by ON resident_change_request(requested_by_user_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_rcr_reviewed_by ON resident_change_request(reviewed_by_user_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_rcr_requested_changes_gin ON resident_change_request USING gin (requested_changes);"

# Optional: explicit approvals table to record multiple approval actions over time
${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'approval_decision') THEN
    CREATE TYPE approval_decision AS ENUM ('APPROVE', 'REJECT');
  END IF;
END
\$\$;
"

${PSQL} -c "
CREATE TABLE IF NOT EXISTS change_request_approval (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_request_id uuid NOT NULL REFERENCES resident_change_request(id) ON DELETE CASCADE,
  decided_by_user_id uuid REFERENCES app_user(id) ON DELETE SET NULL,
  decision approval_decision NOT NULL,
  note text,
  decided_at timestamptz NOT NULL DEFAULT now()
);
"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_cra_change_request_id ON change_request_approval(change_request_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_cra_decided_by_user_id ON change_request_approval(decided_by_user_id);"

# 6) Audit log
${PSQL} -c "
CREATE TABLE IF NOT EXISTS audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  actor_user_id uuid REFERENCES app_user(id) ON DELETE SET NULL,
  actor_email citext,

  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,

  -- before/after snapshots (or partial)
  before_data jsonb,
  after_data jsonb,

  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,

  ip_address inet,
  user_agent text,

  created_at timestamptz NOT NULL DEFAULT now()
);
"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at DESC);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_audit_log_actor_user_id ON audit_log(actor_user_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON audit_log(entity_type, entity_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_audit_log_metadata_gin ON audit_log USING gin (metadata);"

# 7) CSV import tracking
${PSQL} -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'csv_import_status') THEN
    CREATE TYPE csv_import_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED');
  END IF;
END
\$\$;
"

${PSQL} -c "
CREATE TABLE IF NOT EXISTS csv_import_job (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by_user_id uuid REFERENCES app_user(id) ON DELETE SET NULL,

  original_filename text NOT NULL,
  status csv_import_status NOT NULL DEFAULT 'PENDING',

  total_rows integer NOT NULL DEFAULT 0,
  inserted_rows integer NOT NULL DEFAULT 0,
  updated_rows integer NOT NULL DEFAULT 0,
  error_rows integer NOT NULL DEFAULT 0,

  error_summary text,

  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz
);
"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_csv_import_job_created_at ON csv_import_job(created_at DESC);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_csv_import_job_status ON csv_import_job(status);"

${PSQL} -c "
CREATE TABLE IF NOT EXISTS csv_import_row_error (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES csv_import_job(id) ON DELETE CASCADE,
  row_number integer NOT NULL,
  raw_row jsonb,
  error_message text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_id, row_number)
);
"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_csv_import_row_error_job_id ON csv_import_row_error(job_id);"

# 8) Seed data (roles, and minimal demo data)
${PSQL} -c "
INSERT INTO role (name, description)
VALUES
  ('admin', 'Administrator with full access'),
  ('resident', 'Resident with limited self-service access')
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description;
"

# Create a default admin user (password hash is a placeholder for now; backend should update with real hashing).
# Note: This is intended as a dev bootstrap account.
${PSQL} -c "
INSERT INTO app_user (email, password_hash, display_name, is_active)
VALUES ('admin@example.com', 'DEV_ONLY_REPLACE_WITH_REAL_HASH', 'Default Admin', true)
ON CONFLICT (email) DO NOTHING;
"

# Ensure default admin has admin role
${PSQL} -c "
WITH r AS (SELECT id AS role_id FROM role WHERE name='admin'),
     u AS (SELECT id AS user_id FROM app_user WHERE email='admin@example.com')
INSERT INTO user_role (user_id, role_id)
SELECT u.user_id, r.role_id
FROM u, r
ON CONFLICT DO NOTHING;
"

# Seed a few residents for UI testing/search. Idempotent using a natural key (unit + name).
${PSQL} -c "
INSERT INTO resident (first_name, last_name, unit, phone, email, is_active)
VALUES
  ('Alex', 'Johnson', '1A', '555-0101', 'alex.johnson@example.com', true),
  ('Sam', 'Lee', '2B', NULL, NULL, true),
  ('Taylor', 'Nguyen', '10C', '555-0110', 'taylor.nguyen@example.com', true),
  ('Jordan', 'Patel', '3D', '555-0103', NULL, true)
ON CONFLICT DO NOTHING;
"

echo "Migrations complete."
