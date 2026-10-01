import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./types";
import type { Env } from "../env";

export function getSupabaseClient(env: Env["Bindings"]): SupabaseClient<Database> {
	return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
		auth: { persistSession: false },
	}) as SupabaseClient<Database>;
}

/** Client with anon key for JWT verification (auth.getUser) */
export function getSupabaseAuthClient(env: Env["Bindings"]): SupabaseClient<Database> {
	const key = env.SUPABASE_ANON_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY;
	return createClient(env.SUPABASE_URL, key, { auth: { persistSession: false } }) as SupabaseClient<Database>;
}
