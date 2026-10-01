import "dotenv/config";
import { serve } from "@hono/node-server";
import { app } from "./app";
import type { Env } from "./env";
import { resolveElevenLabsLocaleBinding } from "./lib/speed-dating-ai";

/** Bindings from process.env (load .env in apps/api for local dev) */
function getBindings(): Env["Bindings"] {
	return {
		SUPABASE_URL: process.env.SUPABASE_URL ?? "",
		SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY ?? "",
		SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
		MISTRAL_API_KEY: process.env.MISTRAL_API_KEY,
		ELEVENLABS_API_KEY: process.env.ELEVENLABS_API_KEY,
		SPEED_DATING_AI_SERVER_ACTIVATION: process.env.SPEED_DATING_AI_SERVER_ACTIVATION,
		ELEVENLABS_AGENT_ID_JA: process.env.ELEVENLABS_AGENT_ID_JA,
		ELEVENLABS_AGENT_ID_EN: process.env.ELEVENLABS_AGENT_ID_EN,
		ELEVENLABS_VOICE_ID_JA: process.env.ELEVENLABS_VOICE_ID_JA,
		ELEVENLABS_VOICE_ID_EN: process.env.ELEVENLABS_VOICE_ID_EN,
		ELEVENLABS_MODEL_ID_JA: process.env.ELEVENLABS_MODEL_ID_JA,
		ELEVENLABS_MODEL_ID_EN: process.env.ELEVENLABS_MODEL_ID_EN,
		BATCH_TIMEZONE: process.env.BATCH_TIMEZONE,
		PROFILE_GENERATION_WAIVER_USER_ID: process.env.PROFILE_GENERATION_WAIVER_USER_ID,
		PROFILE_GENERATION_WAIVER_EXPIRES_AT: process.env.PROFILE_GENERATION_WAIVER_EXPIRES_AT,
	};
}

serve(
	{
		fetch: (req, nodeEnv, ctx) =>
			app.fetch(req, { ...nodeEnv, ...getBindings() }, ctx),
		port: 3001,
	},
	(info) => {
		const bindings = getBindings();
		const hasMistral = Boolean(bindings.MISTRAL_API_KEY?.trim());
		const hasElevenLabsJa = Boolean(resolveElevenLabsLocaleBinding(bindings, "ja"));
		const hasElevenLabsEn = Boolean(resolveElevenLabsLocaleBinding(bindings, "en"));
		console.log(`Server is running on http://localhost:${info.port}`);
		console.log(`[env] MISTRAL_API_KEY: ${hasMistral ? "set" : "NOT SET"}`);
		console.log(`[env] ElevenLabs JA binding: ${hasElevenLabsJa ? "set" : "NOT SET"}`);
		console.log(`[env] ElevenLabs EN binding: ${hasElevenLabsEn ? "set" : "NOT SET"}`);
		if (!hasMistral) {
			console.warn("[env] Mistral features will fail. Set MISTRAL_API_KEY in .mise.local.toml");
		}
		if (!hasElevenLabsJa || !hasElevenLabsEn) {
			console.warn("[env] ElevenLabs voice features will fail. Set the API key plus JA/EN agent, voice, and model bindings");
		}
	},
);
