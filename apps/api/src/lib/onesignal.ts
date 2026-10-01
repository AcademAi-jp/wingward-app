/**
 * Thin wrapper around the OneSignal REST API's `POST /notifications` and
 * the User Model's `PATCH /apps/{app_id}/users/by/{alias_label}/{alias_id}`.
 *
 * Host/path confirmed against OneSignal's current official docs (fetched
 * 2026-08-19, orchestrator review round 2, finding #2):
 *  - Create message: `POST https://api.onesignal.com/notifications`.
 *    https://documentation.onesignal.com/reference/create-message
 *  - Update user (tags): `PATCH https://api.onesignal.com/apps/{app_id}/users/by/{alias_label}/{alias_id}`,
 *    body `{ "properties": { "tags": { ... } } }`.
 *    https://documentation.onesignal.com/reference/update-user
 *  The previously-used `https://onesignal.com/api/v1/...` host is OneSignal's
 *  legacy base URL; `https://api.onesignal.com` is current for both
 *  endpoints — this was wrong for both calls, not only the tag one Codex
 *  flagged (verified independently per the review request, not assumed).
 *
 * Idempotency (finding #1, same review round): OneSignal's documented
 * mechanism for `notifications#create` is a request-body `idempotency_key`
 * (RFC 9562 UUID, valid 30 days) — "a request received with this parameter
 * will first look for another notification with the same [key]. If one
 * exists, a notification will not be sent, and the result of the previous
 * operation will instead be returned."
 * https://documentation.onesignal.com/reference/idempotent-notification-requests
 * `sendOneSignalNotification` sends our own `notifications.id` (already a
 * UUID, already unique per logical send) as `idempotency_key`, so a retry
 * of the same row — whether from the deferred executor's bounded backoff
 * or any other future retry path — is recognized by OneSignal itself as
 * the same send instead of dispatching a second push.
 *
 * step-04-notifications.md §3-1 / §5:
 *  - Addressing is by External ID alias only (`user_profiles.id`) — never a
 *    device token / player_id.
 *  - `data` must carry only `scenario_id` / `notification_id` / `deep_link`.
 *  - The REST API key is a Cloudflare secret injected by the caller; this
 *    module never reads it from anywhere else and never logs it.
 *  - PR #26's lesson applies here too: the raw response body from OneSignal
 *    (which can include arbitrary text OneSignal chose to put in an error)
 *    must never be handed back to an API client. Callers get a small,
 *    typed result; the raw body only ever reaches `console.error`.
 */

const ONESIGNAL_API_BASE = "https://api.onesignal.com";
const ONESIGNAL_NOTIFICATIONS_URL = `${ONESIGNAL_API_BASE}/notifications`;

export interface OneSignalNotificationData {
	scenario_id: string;
	notification_id: string;
	deep_link: string;
}

export interface SendOneSignalNotificationParams {
	appId: string;
	apiKey: string;
	/** `user_profiles.id` — the OneSignal External ID alias for this recipient. */
	externalUserId: string;
	heading: string;
	content: string;
	data: OneSignalNotificationData;
}

export type SendOneSignalNotificationResult =
	| { ok: true; oneSignalId: string; recipients: number }
	| { ok: false };

/**
 * Sends one push via OneSignal's External ID addressing, idempotent on
 * `params.data.notification_id` (our own `notifications.id`) — see the
 * module doc comment above for the mechanism and citation.
 *
 * Returns `{ ok: false }` on any transport failure or non-2xx response;
 * the caller never sees the response body (logged server-side only).
 * `recipients: 0` on a 2xx response is a normal, expected outcome (the
 * recipient has no active push subscription — OneSignal's docs describe
 * this case as a 200 whose `id` can be missing or an empty string, not an
 * error) — the caller decides how to treat that, this function does not.
 */
export async function sendOneSignalNotification(params: SendOneSignalNotificationParams): Promise<SendOneSignalNotificationResult> {
	const body = {
		app_id: params.appId,
		// Idempotent on our own notification row id — a retry of the same row
		// (e.g. services/notifications.ts's deferred-send backoff) is
		// recognized by OneSignal as the same logical send. See the module
		// doc comment for the citation.
		idempotency_key: params.data.notification_id,
		include_aliases: { external_id: [params.externalUserId] },
		target_channel: "push",
		headings: { en: params.heading },
		contents: { en: params.content },
		data: params.data,
	};

	let response: Response;
	try {
		response = await fetch(ONESIGNAL_NOTIFICATIONS_URL, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Key ${params.apiKey}`,
			},
			body: JSON.stringify(body),
		});
	} catch (e) {
		console.error("[onesignal] request failed (network/transport error):", e instanceof Error ? e.message : e);
		return { ok: false };
	}

	const rawText = await response.text().catch(() => "");

	if (!response.ok) {
		// Never reflect this body to an API client (PR #26 lesson #1) — the
		// detail (validation errors, rate limits, whatever OneSignal chose to
		// put in the body) is only useful server-side.
		console.error(`[onesignal] send failed, status=${response.status} body=${rawText}`);
		return { ok: false };
	}

	let parsed: { id?: unknown; recipients?: unknown } = {};
	try {
		parsed = rawText ? JSON.parse(rawText) : {};
	} catch (e) {
		console.error("[onesignal] 2xx response body was not valid JSON:", e instanceof Error ? e.message : e, rawText);
		return { ok: false };
	}

	// A 200 with no `id` (or an empty `id`) is OneSignal's documented shape
	// for "no valid subscriptions in the target audience" — a normal
	// suppression outcome, not an error — so it must not be classified as
	// ok:false here. `id` is only ever a string when present, so treating a
	// non-string/absent `id` as "" is safe and keeps this a single check.
	const oneSignalId = typeof parsed.id === "string" ? parsed.id : "";
	const recipients = typeof parsed.recipients === "number" ? parsed.recipients : 0;
	return { ok: true, oneSignalId, recipients };
}

export interface SetOneSignalTagsParams {
	appId: string;
	apiKey: string;
	externalUserId: string;
	tags: Record<string, string>;
}

/**
 * Sets segmentation tags (billing status / meetup experience / timezone,
 * step-04-notifications.md §3-1) on a OneSignal user via External ID.
 * Same "never reflect the body" discipline as the send path above.
 */
export async function setOneSignalTags(params: SetOneSignalTagsParams): Promise<{ ok: boolean }> {
	const url = `${ONESIGNAL_API_BASE}/apps/${params.appId}/users/by/external_id/${encodeURIComponent(params.externalUserId)}`;
	let response: Response;
	try {
		response = await fetch(url, {
			method: "PATCH",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Key ${params.apiKey}`,
			},
			body: JSON.stringify({ properties: { tags: params.tags } }),
		});
	} catch (e) {
		console.error("[onesignal] tag update failed (network/transport error):", e instanceof Error ? e.message : e);
		return { ok: false };
	}

	if (!response.ok) {
		const rawText = await response.text().catch(() => "");
		console.error(`[onesignal] tag update failed, status=${response.status} body=${rawText}`);
		return { ok: false };
	}
	return { ok: true };
}
