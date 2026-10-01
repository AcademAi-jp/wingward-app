-- Read-only composite regression test; creates no users, profiles or fabricated history.
BEGIN;
DO $$
DECLARE
  member_id uuid;
  a public.user_profiles;
  ren public.user_profiles;
  outsider public.user_profiles;
  second_new public.user_profiles;
BEGIN
  a := jsonb_populate_record(NULL::public.user_profiles, '{"age_verified_at":"2026-09-30T00:00:00Z","onboarding_settings_completed_at":"2026-09-30T00:00:00Z","gender_identity":"nonbinary","preferred_genders":["nonbinary"],"preference_mode":"selected","dating_market":"JP"}'::jsonb);
  ren := a; ren.id := '9d836fee-7b93-41ce-b577-34a63006aaea';
  outsider := a; outsider.id := '11111111-1111-4111-8111-111111111111';
  second_new := a; second_new.id := 'e7c595cb-ff44-5611-aff1-44fb0ca8bf58';
  FOREACH member_id IN ARRAY ARRAY[
    '96b31c0a-b8c4-4536-ada2-f3537dadd146'::uuid,
    '9d836fee-7b93-41ce-b577-34a63006aaea'::uuid,
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid,
    'a88a89e2-5421-5ce9-a33b-76d512898c37'::uuid,
    'e7c595cb-ff44-5611-aff1-44fb0ca8bf58'::uuid,
    'c0195ccd-de1e-5102-ad9c-d5bf4493f493'::uuid,
    '8f46024f-57f6-5156-ab67-579750c25d4f'::uuid,
    '2695146e-fa8a-5ed1-a437-3d97fa1aea73'::uuid,
    '0a6abcf2-03e9-5314-afff-5d31bde7d375'::uuid,
    '67b0d667-d24a-51fd-a328-f51ba95e7f34'::uuid,
    '4e7b3007-217d-59c4-a248-9342bcac383f'::uuid,
    '97e36e35-9a3b-5564-af94-9dd3299054bf'::uuid,
    '5236813d-8309-5f07-addc-363650df398a'::uuid,
    '70d6de4c-fcbd-5087-ab9f-b34cdeae39a1'::uuid,
    '84cbc386-bf1d-5b5f-a58b-bebc74f295cc'::uuid,
    'a2807edf-1b46-5991-a205-2773574ea881'::uuid,
    'fbc07cb0-43fb-5a58-a6a6-e42bd9c89fa6'::uuid,
    '7a1d4255-6f79-55e6-a3d5-00649f85c0c2'::uuid,
    'fb57a1b1-803a-5018-a200-5287789cf68f'::uuid,
    '0e7b28b3-41cf-51ab-af21-7bc5c00c5360'::uuid,
    'e83da28b-ea0b-594d-a8e2-94cbdc2bc016'::uuid,
    'd0d9d2b8-ad16-5bc7-afbb-a08ee5ceffe6'::uuid,
    '66633798-57b9-5dbd-a092-10e669ef142d'::uuid
  ] LOOP
    a.id := member_id;
    IF NOT wingward_private.synthetic_matching_member(member_id)
       OR wingward_private.is_mutually_eligible(a,outsider)
       OR wingward_private.is_mutually_eligible(outsider,a)
       OR (member_id <> ren.id AND (NOT wingward_private.is_mutually_eligible(a,ren) OR NOT wingward_private.is_mutually_eligible(ren,a)))
       OR (member_id <> second_new.id AND NOT wingward_private.is_mutually_eligible(a,second_new))
       OR wingward_private.is_mutually_eligible(a,a) THEN
      RAISE EXCEPTION 'Demo cohort isolation assertion failed';
    END IF;
    a.age_verified_at := NULL;
    IF wingward_private.is_mutually_eligible(a,ren) THEN
      RAISE EXCEPTION 'Dormant cohort eligibility assertion failed';
    END IF;
    a.age_verified_at := '2026-09-30T00:00:00Z';
  END LOOP;
  IF wingward_private.synthetic_matching_member(outsider.id)
     OR wingward_private.synthetic_matching_member(NULL)
     OR has_function_privilege('authenticated','wingward_private.synthetic_matching_member(uuid)','execute')
     OR has_function_privilege('anon','wingward_private.synthetic_matching_member(uuid)','execute')
     OR has_function_privilege('service_role','wingward_private.synthetic_matching_member(uuid)','execute') THEN
    RAISE EXCEPTION 'Demo registry privileges assertion failed';
  END IF;
END $$;

ROLLBACK;
