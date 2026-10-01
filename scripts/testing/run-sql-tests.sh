#!/usr/bin/env bash
# Apply and test only in fresh databases in an ephemeral local/CI container.
# No remote URL, password, host psql installation, or Supabase credentials.
set -euo pipefail
export LC_ALL=C
container=${1:?Usage: run-sql-tests.sh CONTAINER_ID [REPOSITORY_ROOT]}
repo=${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid synthetic container identifier' >&2; exit 1; }
[[ -d "$repo/supabase/migrations" && -d "$repo/supabase/tests" ]] || { echo 'Missing SQL migration/test directories' >&2; exit 1; }
shopt -s nullglob
migrations=("$repo"/supabase/migrations/*.sql)
tests=("$repo"/supabase/tests/*.sql)
(( ${#migrations[@]} > 0 && ${#tests[@]} > 0 )) || { echo 'Empty SQL migration or root test suite' >&2; exit 1; }
for file in "${migrations[@]}"; do
  [[ $(basename "$file") =~ ^[0-9]{14}_[a-zA-Z0-9_]+\.sql$ ]] || { echo 'Invalid migration filename' >&2; exit 1; }
done
# Use the image's own client. Every failure propagates through the pipeline.
psql_db() { docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d "$1"; }
create_database() {
  printf 'CREATE DATABASE %s TEMPLATE template0;\n' "$1" | psql_db postgres
  psql_db "$1" < "$script_dir/bootstrap.sql"
}
main_db="wingward_sql_ci_$$"
create_database "$main_db"
for file in "${migrations[@]}"; do
  echo "Migration: $(basename "$file")"
  psql_db "$main_db" < "$file"
done
for file in "${tests[@]}"; do
  echo "SQL test: $(basename "$file")"
  psql_db "$main_db" < "$file"
done
# The historical contract must run against its own schema prefix, not against
# the current time-only meetup behavior. Its presence makes this run required.
historical="$repo/supabase/tests/historical/33_chat_meetup_sessions_before_time_only.sql"
if [[ -f "$historical" ]]; then
  prefix='20260930033150'
  found=false
  historical_db="${main_db}_historical"
  create_database "$historical_db"
  for file in "${migrations[@]}"; do
    stamp=$(basename "$file"); stamp=${stamp%%_*}
    if [[ "$stamp" > "$prefix" ]]; then break; fi
    psql_db "$historical_db" < "$file"
    if [[ "$stamp" == "$prefix" ]]; then found=true; fi
  done
  [[ "$found" == true ]] || { echo 'Missing required historical meetup migration prefix' >&2; exit 1; }
  # Preserve the old Google contract while exercising the additive consent
  # repair against its original and private cloned RPCs as well as today's RPC.
  # Only these additive repairs overlay the frozen historical prefix. Never
  # replace its RPCs with all later migrations: that would hide regressions.
  overlay_migrations=(
    '20261001030337_chat_meetup_session_private_reset.sql'
    '20261001080112_chat_meetup_private_input_validation.sql'
    '20261001080216_chat_meetup_private_input_janitor_budget.sql'
  )
  overlay_tests=(
    '43_chat_meetup_session_private_reset.sql'
    '44_chat_meetup_private_input_validation.sql'
    '46_chat_meetup_private_input_janitor.sql'
  )
  for i in "${!overlay_migrations[@]}"; do
    repair="$repo/supabase/migrations/${overlay_migrations[$i]}"
    [[ -f "$repair" ]] || { echo 'Missing required historical repair migration' >&2; exit 1; }
    psql_db "$historical_db" < "$repair"
  done
  for test_name in '36_google_cafe_place_references.sql' "${overlay_tests[@]}"; do
    regression="$repo/supabase/tests/$test_name"
    [[ -f "$regression" ]] || { echo 'Missing required historical repair regression' >&2; exit 1; }
    echo "SQL historical test: $test_name"
    psql_db "$historical_db" < "$regression"
  done
  echo 'SQL historical test: 33_chat_meetup_sessions_before_time_only.sql'
  psql_db "$historical_db" < "$historical"
fi
echo "SQL migration and root test suites passed (${#migrations[@]} migrations, ${#tests[@]} root tests)."
