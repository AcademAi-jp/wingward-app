import type { JudgeAccess } from "./services/judge-access";
import type { ValidatedDemoJudgeConfig } from "./services/demo-judge-window";
import type { ValidatedRecordingRehearsalConfig } from "./services/recording-rehearsal";

/** Minimal DO namespace interface so env.ts compiles without @cloudflare/workers-types */
export interface DONamespace {
	idFromName(name: string): unknown;
	get(id: unknown): { fetch(req: Request): Promise<Response> };
}

export type Env = {
		Bindings: {
		JUDGE_ACCESS_ENABLED?: string;
		JUDGE_ACCESS_COHORT?: string;
		JUDGE_ACCESS_ISSUED_AT?: string;
		JUDGE_ACCESS_EXPIRES_AT?: string;
		JUDGE_ACCESS_AI_EXPIRES_AT?: string;
		JUDGE_ACCESS_OWNER_AI_EXPIRES_AT?: string;
		DEMO_JUDGE_ENABLED?: string;
		DEMO_JUDGE_COHORT?: string;
		DEMO_JUDGE_ISSUED_AT?: string;
		DEMO_JUDGE_EXPIRES_AT?: string;
		SUPABASE_URL: string;
		SUPABASE_SERVICE_ROLE_KEY: string;
		SUPABASE_ANON_KEY?: string;
		MISTRAL_API_KEY?: string;
		/** Owner-managed secret; never placed in native configuration. */
		OPENAI_API_KEY?: string;
		/** Absent means disabled. Owner enables after local integration is ready. */
		OPENAI_REALTIME_ENABLED?: string;
		/** New Chat scheduling rollout; absent means disabled until local schema/provider review. */
		CHAT_MEETUP_ENABLED?: string;
		/** Exact-value opt-in; production factory additionally requires the trusted rehearsal window and transient projection review. */
		GOOGLE_CAFE_SEARCH_ENABLED?: string;
		/** Server-only Google Maps Platform key; never expose to clients or logs. */
		GOOGLE_MAPS_PLATFORM_API_KEY?: string;
		/** Private post-meetup realtime rollout; absent means disabled. */
		MEETUP_REFLECTION_REALTIME_ENABLED?: string;
		/** Private grounded draft generation; exact enabled only, default closed. */
		MEETUP_REFLECTION_DRAFTS_ENABLED?: string;
		/** Durable matching rollout; absent means disabled until schema/runtime approval. */
		DURABLE_DAILY_BATCH_ENABLED?: string;
		ELEVENLABS_API_KEY?: string;
		/** Server-operator activation gate; absent means the provider routes remain disabled. */
		SPEED_DATING_AI_SERVER_ACTIVATION?: string;
		/** Locale-specific ElevenLabs agent bindings for saved conversation_language. */
		ELEVENLABS_AGENT_ID_JA?: string;
		ELEVENLABS_AGENT_ID_EN?: string;
		/** Locale-specific ElevenLabs voice bindings; never infer these from user gender. */
		ELEVENLABS_VOICE_ID_JA?: string;
		ELEVENLABS_VOICE_ID_EN?: string;
		/** Locale-specific ElevenLabs TTS model readiness bindings. */
		ELEVENLABS_MODEL_ID_JA?: string;
		ELEVENLABS_MODEL_ID_EN?: string;
		/** Non-secret opt-in gate for the private profile-photo Storage provider. */
		PROFILE_PHOTO_STORAGE_ENABLED?: string;
		/** Explicit operator assertion that the configured profile-photo bucket is private. */
		PROFILE_PHOTO_STORAGE_PRIVATE?: string;
		/** Non-secret private Storage bucket name; absent means the photo route stays closed. */
		PROFILE_PHOTO_STORAGE_BUCKET?: string;
		FOX_CONVERSATION?: DONamespace;
		JUDGE_REALTIME_CALLS?: DONamespace;
		/** Shared secret for /api/internal/*; when unset, those routes are disabled. */
		INTERNAL_API_TOKEN?: string;
		/** IANA timezone the daily batch treats as "today". Fixed to Asia/Tokyo; incompatible overrides are rejected. */
		BATCH_TIMEZONE?: string;
		/** OneSignal REST API key, injected as a Cloudflare secret. When unset, the send/tag functions fail closed (no send attempted) — never a fallback to an unauthenticated call. */
		ONESIGNAL_API_KEY?: string;
		/** OneSignal App ID. Not secret by itself, but only meaningful paired with ONESIGNAL_API_KEY. */
		ONESIGNAL_APP_ID?: string;
		/** RevenueCat webhook HMAC secret; server-only and fail-closed when unset. */
		REVENUECAT_WEBHOOK_SECRET?: string;
		/** RevenueCat webhook Authorization value; server-only and fail-closed when unset. */
		REVENUECAT_WEBHOOK_AUTHORIZATION?: string;
		/** Explicit owner-issued recording rehearsal gate; any present field is fail-closed. */
		RECORDING_REHEARSAL_ENABLED?: string;
		RECORDING_REHEARSAL_ISSUED_AT?: string;
		RECORDING_REHEARSAL_EXPIRES_AT?: string;
		RECORDING_REHEARSAL_PAIR?: string;
		/** Explicit fictional-pair permit UUID; DB independently verifies exact window and room. */
		RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID?: string;
		/** Narrow read-only-window exception for one Sora third-interview admission. */
		RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED?: string;
		RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT?: string;
		RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT?: string;
		/** Restrict a writable Sora/Ren window to owner review, settings, and a nonwriting preview. */
		RECORDING_REHEARSAL_OWNER_PREP_ONLY?: string;
		/** Narrow owner-approved Test Store filming mode; closes every AI and meetup route. */
		RECORDING_REHEARSAL_BILLING_ONLY?: string;
		/** One archived replacement of Sora's pre-third-interview draft. */
		RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED?: string;
		/** Optional temporary production E2E profile allowlist; absent means unchanged app behavior. */
		PRODUCTION_E2E_PROFILE_IDS?: string;
		/** Exact fixed synthetic cohort, independently opt-in; never expands the owner list. */
		PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS?: string;
		/** Optional strict UTC activation deadline paired with PRODUCTION_E2E_PROFILE_IDS. */
		PRODUCTION_E2E_EXPIRES_AT?: string;
		/** Owner-requested Sora voice recording only, fixed Sep22 21:00 JST expiry. */
		PRODUCTION_E2E_RECORDING_WINDOW?: string;
		/** Exact profile allowed to use the temporary two-interview generation waiver. */
		PROFILE_GENERATION_WAIVER_USER_ID?: string;
		/** Strict UTC expiry for the temporary two-interview generation waiver. */
		PROFILE_GENERATION_WAIVER_EXPIRES_AT?: string;
		/** Optional production E2E read-only mode; malformed values fail closed when configured. */
		PRODUCTION_E2E_READ_ONLY?: string;
		/** Cap on rows the deferred-send executor processes per invocation (services/notifications.ts). Defaults to a small, easily-changed constant when unset. */
		DEFERRED_SEND_LIMIT?: string;
	};
	Variables: {
		judge_access?: JudgeAccess;
		judge_vendor_active?: boolean;
		demo_judge?: ValidatedDemoJudgeConfig;
		user_id: string; // user_profiles.id
		auth_user_id: string; // auth.users.id
		/** Set only after the temporary production E2E gate has authenticated the request. */
		production_e2e_active?: boolean;
		production_e2e_synthetic?: boolean;
		/** Set only from validated server bindings by the production E2E gate. */
		recording_rehearsal?: ValidatedRecordingRehearsalConfig;
		/** Set by the trusted production E2E gate when mutating paths are closed. */
		production_e2e_read_only?: boolean;
	};
};
