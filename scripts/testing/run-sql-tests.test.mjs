import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const runner = join(root, 'scripts/testing/run-sql-tests.sh');

function fixture({ migration = 'SELECT 1;', sql = 'SELECT 1;', historical = false, historicalPrefix = false, repair = false, regression = false, empty = false, omit = null } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'wingward-sql-runner-'));
  const repo = join(dir, 'repo');
  const bin = join(dir, 'bin');
  mkdirSync(join(repo, 'supabase/migrations'), { recursive: true });
  mkdirSync(join(repo, 'supabase/tests'), { recursive: true });
  mkdirSync(bin);
  if (!empty) {
    writeFileSync(join(repo, 'supabase/migrations/20260101000000_synthetic.sql'), migration);
    writeFileSync(join(repo, 'supabase/tests/01_synthetic.sql'), sql);
  }
  if (historical) {
    mkdirSync(join(repo, 'supabase/tests/historical'));
    writeFileSync(join(repo, 'supabase/tests/historical/33_chat_meetup_sessions_before_time_only.sql'), 'SELECT 1;');
  }
  if (historical) {
    for (const [file, body] of [
      ['supabase/migrations/20261001080112_chat_meetup_private_input_validation.sql', 'SELECT 1; -- INPUT_GUARD'],
      ['supabase/migrations/20261001080216_chat_meetup_private_input_janitor_budget.sql', 'SELECT 1; -- JANITOR_BUDGET'],
      ['supabase/tests/36_google_cafe_place_references.sql', 'SELECT 1; -- GOOGLE_REGRESSION'],
      ['supabase/tests/44_chat_meetup_private_input_validation.sql', 'SELECT 1; -- INPUT_REGRESSION'],
      ['supabase/tests/46_chat_meetup_private_input_janitor.sql', 'SELECT 1; -- JANITOR_REGRESSION'],
    ]) if (file !== omit) writeFileSync(join(repo, file), body);
  }
  if (historicalPrefix) writeFileSync(join(repo, 'supabase/migrations/20260930033150_synthetic_prefix.sql'), 'SELECT 1;');
  if (repair) writeFileSync(join(repo, 'supabase/migrations/20261001030337_chat_meetup_session_private_reset.sql'), 'SELECT 1; -- SESSION_REPAIR');
  if (regression) writeFileSync(join(repo, 'supabase/tests/43_chat_meetup_session_private_reset.sql'), 'SELECT 1; -- SESSION_REGRESSION');
  // A fake Docker transport lets the committed test exercise the actual shell
  // control flow without starting another DB from inside CI. Real SQL runs
  // immediately after this behavioral test in the same required CI step.
  writeFileSync(join(bin, 'docker'), `#!/usr/bin/env node
const args=process.argv.slice(2);
if(args[0]!=='exec'||!args.includes('psql')||!args.includes('-X')||!args.includes('ON_ERROR_STOP=1'))process.exit(70);
let sql='';process.stdin.setEncoding('utf8');process.stdin.on('data',part=>sql+=part);process.stdin.on('end',()=>{
 if(sql.includes('NEGATIVE_MIGRATION_FAIL'))process.exit(41);
 if(sql.includes('NEGATIVE_SQL_TEST_FAIL'))process.exit(42);
 if(sql.includes('SESSION_REPAIR'))console.log('repair applied');
 if(sql.includes('SESSION_REGRESSION'))console.log('regression executed');
 for(const marker of ['INPUT_GUARD','JANITOR_BUDGET','GOOGLE_REGRESSION','INPUT_REGRESSION','JANITOR_REGRESSION'])if(sql.includes(marker))console.log(marker);
});
`, { mode: 0o755 });
  const result = spawnSync('bash', [runner, 'synthetic-container', repo], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, encoding: 'utf8', timeout: 10_000,
  });
  rmSync(dir, { recursive: true, force: true });
  return result;
}

test('runner propagates a migration failure and never reports suite success', () => {
  const result = fixture({ migration: 'NEGATIVE_MIGRATION_FAIL' });
  assert.equal(result.status, 41);
  assert.doesNotMatch(result.stdout, /suites passed/);
});
test('runner propagates a SQL assertion failure and never reports suite success', () => {
  const result = fixture({ sql: 'NEGATIVE_SQL_TEST_FAIL' });
  assert.equal(result.status, 42);
  assert.doesNotMatch(result.stdout, /suites passed/);
});
test('runner rejects an empty suite instead of reporting a green check', () => {
  const result = fixture({ empty: true });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Empty SQL/);
});
test('historical suite requires its precise migration prefix', () => {
  const result = fixture({ historical: true });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing required historical meetup migration prefix/);
});
test('runner succeeds only when migration and SQL streams both succeed', () => {
  const result = fixture();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1 migrations, 1 root tests/);
});

test('session repair and regression execute on both current and historical schemas', () => {
  const result = fixture({ historical: true, historicalPrefix: true, repair: true, regression: true });
  assert.equal(result.status, 0, result.stderr);
  assert.equal((result.stdout.match(/repair applied/g) ?? []).length, 2);
  assert.equal((result.stdout.match(/regression executed/g) ?? []).length, 2);
});
test('historical session regression fails closed if its repair is missing', () => {
  const result = fixture({ historical: true, historicalPrefix: true, regression: true });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing required historical repair migration/);
  assert.doesNotMatch(result.stdout, /suites passed/);
});

// These assertions execute the runner, not a duplicate of its allowlist logic.
test('all additive guards and Google behavior run on both schema contracts', () => {
  const result = fixture({ historical: true, historicalPrefix: true, repair: true, regression: true });
  assert.equal(result.status, 0, result.stderr);
  for (const marker of ['INPUT_GUARD', 'JANITOR_BUDGET', 'GOOGLE_REGRESSION', 'INPUT_REGRESSION', 'JANITOR_REGRESSION'])
    assert.equal(result.stdout.split(marker).length - 1, 2, marker);
});
for (const file of [
  'supabase/migrations/20261001080112_chat_meetup_private_input_validation.sql',
  'supabase/migrations/20261001080216_chat_meetup_private_input_janitor_budget.sql',
  'supabase/tests/36_google_cafe_place_references.sql',
  'supabase/tests/44_chat_meetup_private_input_validation.sql',
  'supabase/tests/46_chat_meetup_private_input_janitor.sql',
]) test(`historical runner rejects missing ${file}`, () => {
  const result = fixture({ historical: true, historicalPrefix: true, repair: true, regression: true, omit: file });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing required historical repair/);
  assert.doesNotMatch(result.stdout, /suites passed/);
});
