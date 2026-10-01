import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { areMutuallyEligible } from "./matching-eligibility";
import { checkFoxConversationCurrentAccess } from "./fox-conversation-access";
import { SYNTHETIC_MATCHING_PROFILE_IDS as ids, DEMO_20260930_PROFILE_IDS as demoIds, ALL_SYNTHETIC_MATCHING_PROFILE_IDS as allIds, JUDGE_20261001_PROFILE_IDS as judgeIds, JUDGE_SEVEN_OWNER_PROFILE_IDS as newOwnerIds, isSyntheticMatchingProfile, SYNTHETIC_MATCHING_EXPIRES_AT, shareMatchingCohort, syntheticGenerationAllowed } from "./synthetic-matching-cohort";

const ordinary = "11111111-1111-4111-8111-111111111111";
const profile = (id: string) => ({ id, age_verified_at: "2026-09-22T00:00:00Z", onboarding_settings_completed_at: "2026-09-22T00:00:00Z", gender_identity: "nonbinary", preferred_genders: ["nonbinary"], preference_mode: "selected", dating_market: "JP" });
describe("synthetic cohort isolation", () => {
  it("rejects both directions of synthetic/ordinary pairs despite otherwise mutual settings", () => {
    for (const id of allIds) {
      expect(areMutuallyEligible(profile(id), profile(ordinary))).toBe(false);
      expect(areMutuallyEligible(profile(ordinary), profile(id))).toBe(false);
    }
    expect(areMutuallyEligible(profile(ids[0]), profile(ids[1]))).toBe(true);
    expect(shareMatchingCohort(ordinary, "22222222-2222-4222-8222-222222222222")).toBe(true);
  });
  it("admits all 20 new candidates and Ren only with normal mutual eligibility", () => {
    expect([...ids, ...demoIds]).toHaveLength(23);
    expect(judgeIds).toHaveLength(7);
    expect(allIds).toHaveLength(32);
    expect(new Set(allIds).size).toBe(32);
    for (const id of demoIds) {
      expect(isSyntheticMatchingProfile(id)).toBe(true);
      expect(areMutuallyEligible(profile(id), profile(ids[1]))).toBe(true);
      expect(areMutuallyEligible(profile(ids[1]), profile(id))).toBe(true);
      expect(areMutuallyEligible({ ...profile(id), age_verified_at: null }, profile(ids[1]))).toBe(false);
      expect(areMutuallyEligible(profile(id), { ...profile(ids[1]), preferred_genders: ["woman"] })).toBe(false);
      expect(areMutuallyEligible(profile(id), { ...profile(ids[1]), dating_market: "US" })).toBe(false);
      expect(areMutuallyEligible(profile(id), profile(id))).toBe(false);
      for (const other of demoIds) {
        expect(areMutuallyEligible(profile(id), profile(other))).toBe(id !== other);
      }
    }
  });
  it("does not widen generation or revive expired legacy runtime for new members", () => {
    const beforeLegacyDeadline = Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT) - 1;
    for (const id of [...demoIds, ...judgeIds, ...newOwnerIds]) {
      for (const other of [...allIds, ordinary]) {
        expect(syntheticGenerationAllowed(id, other, beforeLegacyDeadline)).toBe(false);
        expect(syntheticGenerationAllowed(other, id, beforeLegacyDeadline)).toBe(false);
        expect(syntheticGenerationAllowed(id, other, Date.parse("2026-09-30T00:00:00Z"))).toBe(false);
      }
    }
    expect(ids).toHaveLength(3); // Session/gate/rehearsal still bind exactly this tuple.
    expect(syntheticGenerationAllowed(ordinary, "22222222-2222-4222-8222-222222222222")).toBe(true);
  });
  it("allows only the approved pair, before the fixed deadline", () => {
    const end = Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT);
    expect(syntheticGenerationAllowed(ids[0], ids[1], end - 1)).toBe(true);
    expect(syntheticGenerationAllowed(ids[1], ids[0], end - 1)).toBe(true);
    expect(syntheticGenerationAllowed(ids[0], ids[1], end)).toBe(false);
    expect(syntheticGenerationAllowed(ids[0], ids[2], end - 1)).toBe(false);
    expect(syntheticGenerationAllowed(ids[0], ordinary, end - 1)).toBe(false);
  });
  it("stops background generation after expiry without a database/provider call", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(SYNTHETIC_MATCHING_EXPIRES_AT));
    try {
      const from = vi.fn();
      const result = await checkFoxConversationCurrentAccess({ from } as never, { conversationId: "conversation", matchId: "match", userA: ids[0], userB: ids[1] }, "active");
      expect(result.ok).toBe(false);
      expect(from).not.toHaveBeenCalled();
    } finally { vi.useRealTimers(); }
  });
  it("keeps the new fixture registry and SQL expansion exactly aligned", () => {
    const fixture = JSON.parse(readFileSync(new URL("../../../../scripts/demo-cohort-20260930/fixture.json", import.meta.url), "utf8"));
    const sql = readFileSync(new URL("../../../../supabase/migrations/20260930025440_demo_20260930_synthetic_cohort_isolation.sql", import.meta.url), "utf8");
    expect(fixture.users.map((u: { user_profile: { id: string } }) => u.user_profile.id)).toEqual(demoIds);
    const registry = sql.split("REVOKE ALL")[0];
    expect([...registry.matchAll(/'([a-f0-9-]+)'::uuid/g)].map(match => match[1])).toEqual([...ids, ...demoIds]);
    expect(sql).toContain("IMMUTABLE SECURITY INVOKER SET search_path = ''");
    expect(sql).toContain("FROM PUBLIC, anon, authenticated, service_role");
    expect(sql).not.toMatch(/INSERT INTO|UPDATE public|SECURITY DEFINER|GRANT /i);
  });
  it("keeps the new judge SQL isolation registry aligned without granting legacy generation", () => {
    const sql = readFileSync(new URL("../../../../supabase/migrations/20260930182451_judge_account_admission_and_budget.sql", import.meta.url), "utf8");
    const registry = sql.split("REVOKE ALL")[0];
    expect([...registry.matchAll(/'([a-f0-9-]+)'::uuid/g)].map(match => match[1])).toEqual([...ids,...demoIds,...judgeIds]);
    expect(registry).toContain("IMMUTABLE SECURITY INVOKER SET search_path = ''");
    for (const id of judgeIds) {
      expect(isSyntheticMatchingProfile(id)).toBe(true);
      expect(areMutuallyEligible(profile(id), profile(ordinary))).toBe(false);
      expect(areMutuallyEligible(profile(ordinary), profile(id))).toBe(false);
      expect(syntheticGenerationAllowed(id, ids[1], Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT) - 1)).toBe(false);
    }
  });
  it("keeps the two fresh owner IDs aligned with the additive SQL registry",()=>{
    const sql=readFileSync(new URL("../../../../supabase/migrations/20261001110935_judge_seven_owner_access_budget.sql",import.meta.url),"utf8");
    const registry=sql.split("CREATE OR REPLACE FUNCTION wingward_private.synthetic_matching_member")[1].split("REVOKE ALL")[0];
    expect([...registry.matchAll(/'([a-f0-9-]+)'::uuid/g)].map(match=>match[1])).toEqual(allIds);
    for(const id of newOwnerIds){
      expect(isSyntheticMatchingProfile(id)).toBe(true);
      expect(areMutuallyEligible(profile(id),profile(ordinary))).toBe(false);
      expect(syntheticGenerationAllowed(id,ids[1],Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT)-1)).toBe(false);
    }
  });
  it("keeps the client-immutable SQL backstop and prepared fixture registry aligned", () => {
    const sql = readFileSync(new URL("../../../../supabase/migrations/20260922090904_synthetic_matching_cohort_isolation.sql", import.meta.url), "utf8");
    const fixture = JSON.parse(readFileSync(new URL("../../../../scripts/dev-live/fixtures/synthetic-matching-20260922.json", import.meta.url), "utf8"));
    expect(fixture.accounts.map((a: { profile_id: string }) => a.profile_id)).toEqual(ids);
    for (const id of ids) expect(sql).toContain(`'${id}'::uuid`);
    expect(sql).toContain("synthetic_matching_member(p_left.id) = wingward_private.synthetic_matching_member(p_right.id)");
    expect(sql).toContain("FROM PUBLIC, anon, authenticated, service_role");
  });
});
