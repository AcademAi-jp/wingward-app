/** Legacy runtime tuple: keep session, rehearsal and generation permissions bounded. */
export const SYNTHETIC_MATCHING_PROFILE_IDS = [
  "96b31c0a-b8c4-4536-ada2-f3537dadd146",
  "9d836fee-7b93-41ce-b577-34a63006aaea",
  "d327a193-9eeb-42b1-bac4-fb5bea3ca21f",
] as const;
export const SYNTHETIC_MATCHING_EXPIRES_AT = "2026-09-22T11:30:00Z";
/** Owner-authorized fictional cohort; membership grants isolation only, not activation. */
export const DEMO_20260930_PROFILE_IDS = [
  "a88a89e2-5421-5ce9-a33b-76d512898c37",
  "e7c595cb-ff44-5611-aff1-44fb0ca8bf58",
  "c0195ccd-de1e-5102-ad9c-d5bf4493f493",
  "8f46024f-57f6-5156-ab67-579750c25d4f",
  "2695146e-fa8a-5ed1-a437-3d97fa1aea73",
  "0a6abcf2-03e9-5314-afff-5d31bde7d375",
  "67b0d667-d24a-51fd-a328-f51ba95e7f34",
  "4e7b3007-217d-59c4-a248-9342bcac383f",
  "97e36e35-9a3b-5564-af94-9dd3299054bf",
  "5236813d-8309-5f07-addc-363650df398a",
  "70d6de4c-fcbd-5087-ab9f-b34cdeae39a1",
  "84cbc386-bf1d-5b5f-a58b-bebc74f295cc",
  "a2807edf-1b46-5991-a205-2773574ea881",
  "fbc07cb0-43fb-5a58-a6a6-e42bd9c89fa6",
  "7a1d4255-6f79-55e6-a3d5-00649f85c0c2",
  "fb57a1b1-803a-5018-a200-5287789cf68f",
  "0e7b28b3-41cf-51ab-af21-7bc5c00c5360",
  "e83da28b-ea0b-594d-a8e2-94cbdc2bc016",
  "d0d9d2b8-ad16-5bc7-afbb-a08ee5ceffe6",
  "66633798-57b9-5dbd-a092-10e669ef142d",
] as const;
/** Judge registry identities are isolated permanently; this list never authorizes access. */
export const JUDGE_20261001_PROFILE_IDS = [
  "970f08d1-c1b8-572b-ad42-00277c8facbb",
  "69ef089a-ff8e-5344-8335-8b931364b064",
  "bc7b2853-234f-5191-a720-b88893217597",
  "a8a78dc4-02c2-54a2-b205-486bd44d3387",
  "b0caf6bb-4481-5ac0-ba8f-cbab9baef418",
  "6d527260-24a9-57f6-8051-1c79eea0028f",
  "0ed47fef-1266-5fa9-8852-0a2c6b9dc741",
] as const;
/** Two fresh owner profiles, separate from the previous owner and QA identities. */
export const JUDGE_SEVEN_OWNER_PROFILE_IDS = [
  "56f96c3d-6040-5c57-b6ad-c59284ba4f3c",
  "907cd918-c426-529b-8d36-39aaae2ae1a6",
] as const;
export const ALL_SYNTHETIC_MATCHING_PROFILE_IDS = [
  ...SYNTHETIC_MATCHING_PROFILE_IDS,
  ...DEMO_20260930_PROFILE_IDS,
  ...JUDGE_20261001_PROFILE_IDS,
  ...JUDGE_SEVEN_OWNER_PROFILE_IDS,
] as const;
const members = new Set<string>(ALL_SYNTHETIC_MATCHING_PROFILE_IDS);

export function isSyntheticMatchingProfile(id: string): boolean {
  return members.has(id);
}

/** Permanent isolation is independent of the temporary activation window. */
export function shareMatchingCohort(first: string, second: string): boolean {
  return isSyntheticMatchingProfile(first) === isSyntheticMatchingProfile(second);
}

/** Only Aoi/Ren may generate the one approved conversation. Sora stays empty. */
export function isApprovedSyntheticPair(first: string, second: string): boolean {
  const [a, b] = SYNTHETIC_MATCHING_PROFILE_IDS;
  return (first === a && second === b) || (first === b && second === a);
}

export function syntheticGenerationAllowed(first: string, second: string, now = Date.now()): boolean {
  if (!isSyntheticMatchingProfile(first) && !isSyntheticMatchingProfile(second)) return true;
  return isApprovedSyntheticPair(first, second) && now < Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT);
}
