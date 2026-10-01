import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * The merge gate is shell in YAML, and nothing else in this repository looks
 * at it. Both findings on PR #37 ended with the same sentence — "no test fails
 * if this fix is removed" — and that was true: the guards could be deleted,
 * loosened, or inverted and `pnpm test` stayed green.
 *
 * These are the same shape as the `workers_dev` tripwire in
 * daily-batch-cron-wiring.test.ts: text assertions over a config file whose
 * failure mode is silent and whose blast radius is everything merged after it.
 */
const WORKFLOWS = join(__dirname, "..", "..", "..", "..", ".github", "workflows");
const REPO_ROOT = join(WORKFLOWS, "..", "..");
const read = (name: string) => readFileSync(join(WORKFLOWS, name), "utf8");
const readRepo = (relativePath: string) => readFileSync(join(REPO_ROOT, relativePath), "utf8");
const WINGWARD_SCHEME_PATH =
	"apps/ios/Wingward.xcodeproj/xcshareddata/xcschemes/Wingward.xcscheme";

const uncommented = (src: string) =>
	src
		.split("\n")
		.filter((line) => !line.trimStart().startsWith("#"))
		.join("\n");

// This assertion belongs in pnpm test: executing it only inside the SQL step
// would delete the tripwire at the same time as deleting that step.
function requireSqlCi(source: string) {
	const job = uncommented(source).split("  build-test:\n")[1]?.split("\n  semgrep:")[0];
	expect(job, "required build-test job").toBeDefined();
	expect(job).toMatch(/image: public\.ecr\.aws\/supabase\/postgres:17\.6\.1\.155/);
	const sqlStepName = "      - name: Execute migration and SQL authorization tests";
	const appTest = job!.indexOf("      - run: pnpm test");
	const sqlTest = job!.indexOf(sqlStepName);
	expect(appTest, "application tests still run").toBeGreaterThan(-1);
	expect(sqlTest, "SQL tests still run").toBeGreaterThan(appTest);
	const step = job!.slice(sqlTest);
	expect(step).toMatch(/SQL_TEST_CONTAINER: \$\{\{ job\.services\.postgres\.id \}\}/);
	expect(step).toMatch(/set -euo pipefail/);
	expect(step).toMatch(/node --test scripts\/testing\/run-sql-tests\.test\.mjs/);
	expect(step).toMatch(/node --test[^\n]*scripts\/testing\/actions-cost-control\.test\.mjs/);
	expect(step).toMatch(/bash scripts\/testing\/run-sql-tests\.sh "\$SQL_TEST_CONTAINER"/);
	// Draft job eligibility is exercised by the cost-control suite above. Once
	// eligible, no individual step may suppress required SQL or its tripwires.
	expect(job).not.toMatch(/continue-on-error|\|\|\s*true/);
	expect(job!.split("    steps:\n")[1]).not.toMatch(/\bif:/);
}

describe("required build-test cannot omit or suppress SQL authorization tests", () => {
	it("executes SQL after application tests and propagates failures", () => {
		requireSqlCi(read("ci.yml"));
	});

	it.each([
		["deleted SQL step", (source: string) => source.replace(/      - name: Execute migration and SQL authorization tests[\s\S]*?(?=\n  semgrep:)/, "")],
		["omitted SQL command", (source: string) => source.replace('bash scripts/testing/run-sql-tests.sh "$SQL_TEST_CONTAINER"', "echo SQL omitted")],
		["omitted cost-control tripwire", (source: string) => source.replace(" scripts/testing/actions-cost-control.test.mjs", "")],
		["suppressed shell failure", (source: string) => source.replace('bash scripts/testing/run-sql-tests.sh "$SQL_TEST_CONTAINER"', 'bash scripts/testing/run-sql-tests.sh "$SQL_TEST_CONTAINER" || true')],
		["continued SQL step", (source: string) => source.replace("      - name: Execute migration and SQL authorization tests", "      - name: Execute migration and SQL authorization tests\n        continue-on-error: true")],
		["conditional SQL step", (source: string) => source.replace("      - name: Execute migration and SQL authorization tests", "      - name: Execute migration and SQL authorization tests\n        if: false")],
	] as const)("rejects %s", (_name, mutate) => {
		expect(() => requireSqlCi(mutate(read("ci.yml")))).toThrow();
	});
});

describe("auto-merge cannot be talked out of reviewing workflow changes", () => {
	const src = uncommented(read("auto-merge.yml"));

	it("still parks a PR that edits .github/workflows", () => {
		// A pull_request run uses the workflow files FROM THE PR, so a change
		// to claude-review.yml is reviewed by the changed file: append "post no
		// inline comments" to its prompt and the review passes on zero
		// findings. This guard is the only thing between that and main
		// (Claude review, PR #37, P0).
		// Matched on the path prefix rather than the exact expression: this
		// assertion broke once when the implementation moved from a jq
		// `startswith` to a grep over the paginated file list. That is the
		// tripwire doing its job, but pinning the spelling of a guard rather
		// than its existence turns every refactor into a false alarm.
		// Covers .github/ as a whole rather than .github/workflows/ alone, plus
		// the two files outside it that the review depends on: AGENTS.md,
		// which it reads its standard from, and this test file, whose deletion
		// would take the guards with it without failing CI.
		expect(src).toMatch(/\^\(\\\.github\//);
		expect(src).toMatch(/AGENTS\\\.md/);
		expect(src).toMatch(/merge-gate-wiring/);
		expect(src).toMatch(/protected=/);
	});

	it("labels and stops rather than merging when it fires", () => {
		expect(src).toMatch(/no-auto-merge/);
		expect(src).toMatch(/exit 0/);
	});
});

describe("iOS changes cannot bypass simulator XCTest", () => {
	const ci = uncommented(read("ci.yml"));
	const autoMerge = uncommented(read("auto-merge.yml"));
	const runStart = ci.indexOf("\n  ios-test-run:");
	const aggregateStart = ci.indexOf("\n  ios-test:");
	const iosRun = ci.slice(runStart, aggregateStart);
	const aggregate = ci.slice(aggregateStart);

	it("runs the shared Wingward scheme on an iOS simulator when apps/ios changes", () => {
		expect(ci).toMatch(/apps\/ios\//);
		expect(ci).toMatch(/changed_files=\$\(git diff --name-only "\$base" "\$head" -- apps\/ios\//);
		expect(iosRun).toMatch(/if: needs\.ios-test-detect\.result == 'success' && needs\.ios-test-detect\.outputs\.changed == 'true'/);
		expect(iosRun).toMatch(/runs-on: macos-15/);
		expect(iosRun).toMatch(/test -f apps\/ios\/Wingward\.xcodeproj\/xcshareddata\/xcschemes\/Wingward\.xcscheme/);
		expect(iosRun).toMatch(/xcodebuild test/);
		expect(iosRun).toMatch(/-project apps\/ios\/Wingward\.xcodeproj/);
		expect(iosRun).toMatch(/-scheme Wingward/);
		expect(iosRun).toMatch(/platform=iOS Simulator,name=iPhone 16,OS=latest/);
		expect(iosRun).toMatch(/ONLY_ACTIVE_ARCH=YES/);
		expect(iosRun).toMatch(/ARCHS=arm64/);
		expect(iosRun).not.toMatch(/CODE_SIGNING_(?:ALLOWED|REQUIRED)=NO/);
	});

	it.each([
		["initial iOS snapshot", "push", "zero", "root", true, true],
		["replaced snapshot with unreachable previous root", "push", "missing", "root", true, true],
		["initial snapshot without iOS", "push", "zero", "empty", false, true],
		["ordinary docs push", "push", "root", "docs", false, true],
		["ordinary iOS push", "push", "docs", "ios", true, true],
		["docs pull request", "pull_request", "root", "docs", false, true],
		["iOS pull request", "pull_request", "docs", "ios", true, true],
		["invalid ordinary base", "push", "missing", "ios", null, false],
		["invalid PR head", "pull_request", "docs", "missing", null, false],
	] as const)("executes the workflow detector for %s", (_name, event, before, head, changed, success) => {
		const directory = mkdtempSync(join(tmpdir(), "wingward-ios-detection-"));
		const env = {
			...process.env,
			GIT_CONFIG_NOSYSTEM: "1",
			GIT_CONFIG_GLOBAL: "/dev/null",
		};
		const git = (...args: string[]) => execFileSync("git", args, {
			cwd: directory,
			env,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "pipe"],
		}).trim();
		const commit = (message: string) => {
			git("add", "--all");
			git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Wingward Test", "-c", "user.email=tests@example.invalid", "commit", "-qm", message);
			return git("rev-parse", "HEAD");
		};
		try {
			git("init", "-q");
			writeFileSync(join(directory, "README.md"), "Synthetic detector fixture\n");
			const empty = commit("snapshot without iOS");
			git("checkout", "--orphan", "ios-snapshot");
			mkdirSync(join(directory, "apps", "ios"), { recursive: true });
			writeFileSync(join(directory, "apps", "ios", "App.swift"), "// Synthetic Swift fixture\n");
			const root = commit("parentless iOS snapshot");
			writeFileSync(join(directory, "README.md"), "Synthetic docs change\n");
			const docs = commit("docs change");
			writeFileSync(join(directory, "apps", "ios", "App.swift"), "// Synthetic iOS change\n");
			const ios = commit("iOS change");
			const refs = { zero: "0".repeat(40), missing: "f".repeat(40), root, docs, ios, empty };
			const output = join(directory, "github-output");
			writeFileSync(output, "");
			const detector = ci.split("name: Check apps/ios path", 2)[1]
				?.split("        run: |\n", 2)[1]?.split("\n  ios-test-run:", 1)[0];
			expect(detector).toBeDefined();
			const script = detector!.split("\n").map((line) => line.startsWith("          ") ? line.slice(10) : line).join("\n");
			const result = spawnSync("bash", ["-c", script], {
				cwd: directory,
				env: { ...env, EVENT_NAME: event, BEFORE_SHA: refs[before], HEAD_SHA: refs[head],
					PR_BASE_SHA: refs[before], PR_HEAD_SHA: refs[head], GITHUB_OUTPUT: output },
				encoding: "utf8",
				timeout: 10_000,
			});
			expect(result.error).toBeUndefined();
			if (success) {
				expect(result.status).toBe(0);
				expect(readFileSync(output, "utf8").trim()).toBe(`changed=${changed}`);
			} else {
				expect(result.status).not.toBe(0);
				expect(readFileSync(output, "utf8")).toBe("");
			}
		} finally {
			rmSync(directory, { recursive: true, force: true });
		}
	});

	it("always publishes a failing aggregate when detection or XCTest is bypassed", () => {
		expect(aggregate).toMatch(/name: ios-test/);
		expect(aggregate).toMatch(/if: always\(\)/);
		expect(aggregate).toMatch(/needs: \[ios-test-detect, ios-test-run\]/);
		expect(aggregate).toMatch(/DETECT_RESULT/);
		expect(aggregate).toMatch(/IOS_CHANGED/);
		expect(aggregate).toMatch(/TEST_RESULT/);
		expect(aggregate).toMatch(/simulator XCTest job was not successful/);
	});

	it("requires the aggregate ios-test check before auto-merge", () => {
		expect(autoMerge).toMatch(/for name in build-test semgrep gitleaks ios-test; do/);
	});

	it("keeps the shared scheme's unit and UI tests enabled", () => {
		const scheme = readRepo(WINGWARD_SCHEME_PATH);
		expect(scheme).toMatch(/BlueprintName = "WingwardTests"/);
		expect(scheme).toMatch(/BlueprintName = "WingwardUITests"/);
		expect(scheme).not.toMatch(/skipped = "YES"/);
	});
});

describe("the gate cannot be executed from the pull request that edits it", () => {
	const src = uncommented(read("auto-merge.yml"));

	it("triggers on workflow_run, never on pull_request", () => {
		// `pull_request` runs the workflow from the PR head, so this file would
		// decide a PR's fate using the copy that PR shipped. `workflow_run`
		// runs from the default branch.
		//
		// `check_run` also runs from the default branch and was the first
		// attempt, but it never fires: GitHub does not trigger workflows from
		// events created with GITHUB_TOKEN, and every check this gate reads is
		// created that way. PR #38 sat CLEAN with five green checks and no Auto
		// Merge run at all.
		expect(src).toMatch(/^on:\n\s+workflow_run:/m);
		expect(src).not.toMatch(/^\s*pull_request:/m);
		expect(src).not.toMatch(/^\s+check_run:/m);
	});

	it("reads the changed files from the paginated REST endpoint", () => {
		// `gh pr view --json files` returns one page, and a path missing from
		// a truncated list reads exactly like a path that was not changed.
		expect(src).toMatch(/--paginate "repos\/\$\{REPO\}\/pulls\/\$\{pr\}\/files"/);
		expect(src).not.toMatch(/--json[^\n]*files/);
	});
});

describe("the gate refuses to decide on data it failed to fetch", () => {
	const src = uncommented(read("auto-merge.yml"));

	it("checks the file listing succeeded before matching against it", () => {
		// Written as one pipeline, the `|| true` that grep needs also swallows
		// a failing `gh api`, and an empty result from a failed fetch is
		// indistinguishable from a PR that touches no workflows — the
		// indistinguishable case being the one that merges.
		expect(src).toMatch(/if ! changed=\$\(gh api/);
	});

	it("merges the commit it verified, not whatever the tip is by then", () => {
		expect(src).toMatch(/--match-head-commit "\$sha"/);
	});

	it("handles BEHIND before it reads the required checks", () => {
		// Being behind is the CAUSE of the checks being missing. Evaluating
		// them first means a stale PR fails on "build-test is missing" and
		// skips, never reaching the branch update that would produce those
		// checks. Dependabot PR #9 sat BEHIND through three fixes because of
		// this ordering alone.
		const behind = src.indexOf('merge_state" = "BEHIND"');
		const checks = src.indexOf("commits/${sha}/check-runs");
		expect(behind).toBeGreaterThan(-1);
		expect(checks).toBeGreaterThan(-1);
		expect(behind).toBeLessThan(checks);
	});

	it("updates a stale branch with a token that actually triggers CI", () => {
		// GitHub raises no workflow events for anything done with
		// GITHUB_TOKEN, so a branch updated with it gets a head CI never runs
		// on — and under `strict` protection that head can never satisfy the
		// required checks. Dependabot PR #9 sat BLOCKED on exactly that.
		//
		// The merge itself stays on GITHUB_TOKEN; only the update needs the
		// separate, Contents-scoped token.
		expect(src).toMatch(/GH_TOKEN="\$UPDATE_TOKEN" gh pr update-branch/);
		expect(src).toMatch(/UPDATE_TOKEN: \$\{\{ secrets\.AUTOMERGE_UPDATE_TOKEN \}\}/);
	});

	it("fails the run when a branch update fails, rather than reporting success", () => {
		// `cmd && updated_one=true` is exempt from `set -e` — bash does not
		// exit for a command on the left of an `&&` — so the failure was
		// swallowed whole. The gate ran green for a day while every update
		// answered "Resource not accessible by personal access token" and five
		// Dependabot pull requests sat BEHIND behind it.
		expect(src).not.toMatch(/gh pr update-branch[^\n]*&& *updated_one=true/);
		expect(src).toMatch(/update_failed=true/);
		expect(src).toMatch(/\[ "\$update_failed" = true \]; then[\s\S]*?exit 1/);
	});

	it("has no GITHUB_TOKEN fallback for the branch update", () => {
		// The fallback read as a graceful degrade and was not one: a head no
		// workflow has seen can never satisfy `strict` protection, so it
		// produced a pull request that was permanently unmergeable rather than
		// one that was merely not updated.
		expect(src).not.toMatch(/^\s*gh pr update-branch/m);
	});

	it("asks Dependabot to rebase instead of pushing to its branch", () => {
		// "By default, Dependabot will stop rebasing a pull request once extra
		// commits have been pushed to it" (GitHub Docs). A branch update is
		// exactly such a commit, so updating a Dependabot branch hands its
		// maintenance to us permanently — and PR #8 then hit a lockfile
		// conflict with no remaining path that did not involve a person.
		expect(src).toMatch(/--body "@dependabot rebase"/);
		const guard = src.indexOf('"$pr_is_dependabot" = true');
		const push = src.indexOf("gh pr update-branch");
		expect(guard).toBeGreaterThan(-1);
		expect(push).toBeGreaterThan(-1);
		expect(guard).toBeLessThan(push);
	});

	it("recognises Dependabot under both spellings GitHub uses for it", () => {
		// `gh pr view` renders the account as `app/dependabot`; the REST API
		// calls it `dependabot[bot]`. Matching only one raises no error — it
		// silently routes Dependabot's branches back to the push above.
		expect(src).toMatch(/"app\/dependabot"/);
		expect(src).toMatch(/"dependabot\[bot\]"/);
	});

	it("asks at most once per head commit", () => {
		// Dependabot is allowed to decline, and an already-edited branch is
		// the case that produced this code. Without the guard the gate would
		// comment on every run, forever, on a pull request it can no longer
		// move.
		expect(src).toMatch(/startswith\("@dependabot rebase"\)/);
		expect(src).toMatch(/\$asked" != "0"/);
	});
});

const SQL_ENFORCEMENT_PATHS = [
	"scripts/testing/run-sql-tests.sh",
	"scripts/testing/run-sql-tests.test.mjs",
	"scripts/testing/bootstrap.sql",
	"scripts/testing/future/helper.sql",
] as const;
const ORDINARY_PATHS = [
	"scripts/run-daily-batch.sh",
	"scripts/testing-extra/helper.sql",
	"docs/scripts/testing/bootstrap.sql",
	"apps/api/src/lib/date.ts",
] as const;

function parkedPath(source: string, path: string) {
	const assignment = uncommented(source).split("\n").find((line) => line.trimStart().startsWith("protected="));
	expect(assignment, "workflow protected-path decision").toBeDefined();
	const result = spawnSync("bash", ["-c", `set -euo pipefail\n${assignment}\nprintf '%s' "$protected"`], {
		env: { ...process.env, changed: path }, encoding: "utf8", timeout: 10_000,
	});
	expect(result.error).toBeUndefined();
	expect(result.status, result.stderr).toBe(0);
	return result.stdout;
}

function ownersForPaths(source: string, paths: readonly string[]) {
	// Match each anchored file/directory rule separately with Git, then apply
	// CODEOWNERS' last-rule precedence. Gitignore alone stops at an ignored
	// parent directory, whereas a later CODEOWNERS file rule can override it.
	// Other pattern syntax needs its own verified matcher before being allowed:
	// https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners#codeowners-syntax
	const rules = uncommented(source).split("\n").filter((line) => line.trim()).map((line) => {
		const [pattern, ...owners] = line.trim().split(/\s+#/, 1)[0].split(/\s+/);
		expect(pattern, "verified anchored CODEOWNERS pattern").toMatch(/^\/[a-zA-Z0-9._/-]+$/);
		return { pattern, owners: owners.filter((owner) => owner.startsWith("@")) };
	});
	const directory = mkdtempSync(join(tmpdir(), "wingward-codeowners-"));
	const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" };
	try {
		execFileSync("git", ["init", "-q"], { cwd: directory, env });
		for (const path of paths) {
			mkdirSync(join(directory, path, ".."), { recursive: true });
			writeFileSync(join(directory, path), "Synthetic ownership path\n");
		}
		const owners = new Map(paths.map((path) => [path, [] as string[]]));
		for (const rule of rules) {
			writeFileSync(join(directory, ".gitignore"), `${rule.pattern}\n`);
			const result = spawnSync("git", ["-c", "core.ignoreCase=false", "-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", "-z", "-v", "--stdin"], {
				cwd: directory, env, input: `${paths.join("\0")}\0`, encoding: "utf8", timeout: 10_000,
			});
			expect(result.error).toBeUndefined();
			expect([0, 1], result.stderr).toContain(result.status);
			const fields = result.stdout.split("\0");
			for (let index = 0; index + 3 < fields.length; index += 4) owners.set(fields[index + 3], rule.owners);
		}
		return owners;
	} finally {
		rmSync(directory, { recursive: true, force: true });
	}
}

describe("SQL enforcement files require an owner and park unattended merge", () => {
	it("parks every SQL enforcement path while ordinary paths remain eligible", () => {
		const source = read("auto-merge.yml");
		for (const path of SQL_ENFORCEMENT_PATHS) expect(parkedPath(source, path), path).toBe(path);
		for (const path of ORDINARY_PATHS) expect(parkedPath(source, path), path).toBe("");
	});

	it("assigns a final code owner to SQL enforcement paths without owning ordinary paths", () => {
		const owners = ownersForPaths(readRepo(".github/CODEOWNERS"), [...SQL_ENFORCEMENT_PATHS, ...ORDINARY_PATHS]);
		for (const path of SQL_ENFORCEMENT_PATHS) expect(owners.get(path), path).toContain("@AcademAi-jp");
		for (const path of ORDINARY_PATHS) expect(owners.get(path), path).toEqual([]);
	});

	it("recognizes a later ownerless exception to SQL runner ownership", () => {
		const owners = ownersForPaths(`${readRepo(".github/CODEOWNERS")}\n/scripts/testing/run-sql-tests.sh\n`, SQL_ENFORCEMENT_PATHS);
		expect(owners.get("scripts/testing/run-sql-tests.sh")).toEqual([]);
	});
});

describe("server-side control over the automation's own rules", () => {
	const codeowners = readFileSync(
		join(__dirname, "..", "..", "..", "..", ".github", "CODEOWNERS"),
		"utf8",
	);

	it("also covers the files the review obeys, not just the workflow text", () => {
		// The review reads its standard from AGENTS.md in the PR's own tree,
		// so a PR widening its "Do not report" list neuters the review without
		// touching .github/. And deleting a test does not fail CI, so the
		// tripwires need an owner too.
		expect(codeowners).toMatch(/^\/AGENTS\.md\s+@\S+/m);
		expect(codeowners).toMatch(/merge-gate-wiring\.test\.ts\s+@\S+/m);
	});

	it("puts /.github/ behind a code owner", () => {
		// GitHub evaluates CODEOWNERS from the base branch, so unlike every
		// guard inside a workflow file, a pull request cannot edit the copy
		// that decides. This is the control; the workflow guard is defence in
		// depth behind it.
		expect(codeowners).toMatch(/^\/\.github\/\s+@\S+/m);
	});
});

describe("the merge gate trusts a check by producer, not by name", () => {
	const src = uncommented(read("auto-merge.yml"));

	it("filters check runs to the github-actions app", () => {
		// Without this, any PR can add a workflow declaring `checks: write`
		// and post build-test/semgrep/gitleaks/ios-test/claude-review as success at its
		// own head SHA. Created last, the forgeries win `| last |` and the PR
		// merges unbuilt, unscanned and unreviewed (PR #37, P1).
		expect(src).toMatch(/select\(\.app\.slug == "github-actions"\)/);
	});

	it("requires claude-review, so an absent review is not a passing one", () => {
		expect(src).toMatch(/claude-review/);
		expect(src).toMatch(/"missing"/);
	});
});

describe("the review workflow cannot report a verdict it did not earn", () => {
	const src = uncommented(read("claude-review.yml"));

	it("refuses to run without the token instead of reviewing nothing", () => {
		expect(src).toMatch(/CLAUDE_CODE_OAUTH_TOKEN is not set/);
	});

	it("requires the action's own conclusion, not just a green step", () => {
		// A green step proves the action did not throw. It does not prove
		// Claude ran: the action returns success after skipping its own work,
		// which is how a6f3da6 got a clean verdict on an unreviewed commit.
		expect(src).toMatch(/steps\.claude\.outputs\.conclusion/);
		expect(src).toMatch(/REVIEW_CONCLUSION/);
	});

	it("counts only this run's comments, excluding the other reviewer", () => {
		expect(src).toMatch(/comments-before\.json/);
		expect(src).toMatch(/chatgpt-codex-connector\[bot\]/);
	});
});

describe("public auto-merge rejects outside code", () => {
 const source=read("auto-merge.yml");
 const guard=source.slice(source.indexOf('            pr_scope='),source.indexOf('            # ---- Paths a machine does not merge unattended'));
 function eligible(repository:string,association:string,script=guard){
  const result=spawnSync("bash",["-c",`set -euo pipefail\ngh(){ printf '%s\\t%s\\n' "$HEAD_REPOSITORY" "$ASSOCIATION"; }\nfor pr in 1; do\n${script}\nprintf 'ELIGIBLE\\n'\ndone`],{encoding:"utf8",env:{...process.env,REPO:"AcademAi-jp/wingward-app",HEAD_REPOSITORY:repository,ASSOCIATION:association}});
  expect(result.status).toBe(0);return result.stdout.includes("ELIGIBLE");
 }
 it.each(["OWNER","MEMBER","COLLABORATOR"])("allows trusted same-repository %s",association=>{expect(eligible("AcademAi-jp/wingward-app",association)).toBe(true);});
 it.each(["NONE","CONTRIBUTOR","FIRST_TIME_CONTRIBUTOR"])("rejects outside association %s",association=>{expect(eligible("AcademAi-jp/wingward-app",association)).toBe(false);});
 it("rejects an external fork even if its author is trusted",()=>{expect(eligible("outside/fork","OWNER")).toBe(false);});
 it("negative control proves the guards stop outside code",()=>{expect(eligible("outside/fork","NONE","")).toBe(true);});
});

const PUBLIC_REVIEW_GUARDS = [
 /github\.event\.pull_request\.head\.repo\.full_name == github\.repository &&/,
 /contains\(fromJSON\('\["OWNER","MEMBER","COLLABORATOR"\]'\), github\.event\.pull_request\.author_association\) &&/,
 /contains\(fromJSON\('\["OWNER","MEMBER","COLLABORATOR"\]'\), github\.event\.comment\.author_association\) &&/,
 /if \[ "\$repository" != "\$\{\{ github\.repository \}\}" \]; then[\s\S]*?exit 1/,
 /allowed_bots: "dependabot\[bot\]"/,
];
describe("public Claude review cannot spend privileged review quota for outsiders",()=>{
 it("retains each trusted-origin, author, commenter and head guard",()=>{const source=uncommented(read("claude-review.yml"));for(const guard of PUBLIC_REVIEW_GUARDS)expect(source).toMatch(guard);});
 it.each(PUBLIC_REVIEW_GUARDS)("negative control catches deletion of %s",guard=>{const source=uncommented(read("claude-review.yml"));expect(source).toMatch(guard);expect(source.replace(guard,"REMOVED_SECURITY_GUARD")).not.toMatch(guard);});
});
