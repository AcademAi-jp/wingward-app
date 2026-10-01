import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { jsonError } from "../lib/response";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { isRecordingRehearsalActive } from "../services/recording-rehearsal";
import {
	isRecordingRehearsalPairMember,
	runRecordingRehearsalMatching,
	type RecordingRehearsalMatchingMode,
} from "../services/recording-rehearsal-matching";

const recordingRehearsalMatching = new Hono<Env>();
recordingRehearsalMatching.use("*", async (c, next) => {
	c.header("Cache-Control", "private, no-store");
	await next();
});

function registerMatchingRoute(path: string, mode: RecordingRehearsalMatchingMode) {
	recordingRehearsalMatching.post(path, requireAuth, requireAgeVerified, async (c) => {
		const config = c.get("recording_rehearsal");
		const actorId = c.get("user_id");
		if (!config || !isRecordingRehearsalActive(config)) {
			return c.json({ data: { outcome: "expired", count: 0 } }, 503);
		}
		if (!isRecordingRehearsalPairMember(config, actorId)) {
			return jsonError(c, "FORBIDDEN", "Matching rehearsal is unavailable");
		}

		try {
			const result = await runRecordingRehearsalMatching(
				getSupabaseClient(c.env),
				config,
				actorId,
				mode,
			);
			if (result.outcome === "not_selected_member") {
				return jsonError(c, "FORBIDDEN", "Matching rehearsal is unavailable");
			}
			return c.json({ data: result }, result.outcome === "expired" ? 503 : 200);
		} catch {
			return jsonError(c, "INTERNAL_ERROR", "Matching rehearsal could not be completed");
		}
	});
}

registerMatchingRoute("/matching/preview", "preview");
registerMatchingRoute("/matching/start", "start");

export default recordingRehearsalMatching;
