/**
 * Server-side allow-list for notification deep links (step-04-notifications
 * §5: "ディープリンクは許可リスト方式。任意 URL を開かない。許可リストはサーバ側
 * にも置き、送信時点で検証する"). A deep link that isn't in this list must be
 * rejected before a send is attempted — never opened as an arbitrary URL.
 *
 * Scheme is a fixed custom scheme (`wingward://`), never `http(s)://` — a
 * deep link must never be able to point at an external site. Each entry is a
 * screen path template with a `{param}` placeholder validated as a UUID, so
 * a caller can't smuggle extra path segments, query strings, or a different
 * host through the placeholder.
 *
 * One template per in-app screen a notification scenario (N-01..N-13) can
 * land on; see docs/spec/wingfox-notification-design.md's scenario table.
 * Extending this list is a deliberate, reviewed change — it is the
 * authorization boundary for where a push notification may send a user.
 */

/**
 * The real 8-4-4-4-12 hex UUID shape, not just "36 characters of hex or
 * hyphen" — the looser version this replaced (orchestrator review P3) also
 * matched strings like 36 bare hyphens, which are not UUIDs at all and
 * would have been accepted into an otherwise-valid deep link template.
 */
const UUID_PATTERN = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";

interface DeepLinkTemplate {
	/** Human label for which scenario(s) use this screen, for readability only. */
	readonly label: string;
	readonly pattern: RegExp;
}

const DEEP_LINK_TEMPLATES: readonly DeepLinkTemplate[] = [
	{ label: "N-01/N-02: match Fox conversation result", pattern: new RegExp(`^wingward://match/${UUID_PATTERN}/fox-result$`) },
	{ label: "N-03: chat request", pattern: new RegExp(`^wingward://chat-requests/${UUID_PATTERN}$`) },
	{ label: "N-04..N-06/N-08/N-09: meetup screen", pattern: new RegExp(`^wingward://meetup/${UUID_PATTERN}$`) },
	{ label: "N-07: identity verification", pattern: new RegExp(`^wingward://meetup/${UUID_PATTERN}/verify$`) },
	{ label: "N-10: meetup feedback", pattern: new RegExp(`^wingward://meetup/${UUID_PATTERN}/feedback$`) },
	{ label: "N-11: shared meetup-again result", pattern: new RegExp(`^wingward://meetup/${UUID_PATTERN}/result$`) },
	{ label: "N-12: Fox's learned-analysis screen", pattern: new RegExp(`^wingward://match/${UUID_PATTERN}/fox-learned$`) },
	{ label: "N-13: availability settings", pattern: /^wingward:\/\/availability$/ },
];

/**
 * True only if `deepLink` matches one of the fixed in-app screen templates
 * above exactly (full-string match, no trailing path/query/fragment).
 */
export function isAllowedDeepLink(deepLink: string): boolean {
	if (typeof deepLink !== "string" || deepLink.length === 0) return false;
	return DEEP_LINK_TEMPLATES.some((t) => t.pattern.test(deepLink));
}
