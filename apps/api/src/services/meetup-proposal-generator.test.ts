import { beforeEach, describe, expect, it, vi } from "vitest";

const chatComplete = vi.fn();
vi.mock("./mistral", () => ({
	chatComplete: (...args: unknown[]) => chatComplete(...args),
	MISTRAL_LARGE: "mistral-large-test",
}));

import { createMeetupProposalGenerator } from "./meetup-proposal-generator";
import type { ProposalGeneratorInput } from "./meetups";

const NOW = new Date("2026-09-04T00:00:00.000Z");

const validInput: ProposalGeneratorInput = {
	preferences: {
		first: {
			availability: [{ starts_at: "2026-09-10T10:00:00+09:00", ends_at: "2026-09-10T12:00:00+09:00" }],
			areas: ["Tokyo/Chiyoda"],
			budget_band: "medium",
			formats: ["cafe"],
			constraints: {},
		},
		second: {
			availability: [{ starts_at: "2026-09-11T10:00:00+09:00", ends_at: "2026-09-11T12:00:00+09:00" }],
			areas: ["Tokyo/Shibuya"],
			budget_band: "low",
			formats: ["meal"],
			constraints: {},
		},
	},
	interaction_dna: [
		{ feature_id: 1, normalized_score: 0.8, confidence: 0.9, source_phase: "quiz" },
	],
};

const validCandidates = [
	{
		starts_at: "2026-09-10T10:00:00+09:00",
		timezone: "Asia/Tokyo",
		area: "Tokyo/Chiyoda",
		format: "cafe",
		rationale: "Fits the shared morning availability.",
	},
	{
		starts_at: "2026-09-11T11:00:00+09:00",
		timezone: "Asia/Tokyo",
		area: "Tokyo/Shibuya",
		format: "meal",
		rationale: "Fits the shared area and meal preference.",
	},
	{
		starts_at: "2026-09-12T12:00:00+09:00",
		timezone: "Asia/Tokyo",
		area: "Tokyo/Chiyoda",
		format: "online",
		rationale: "Offers a low-friction alternative.",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

describe("createMeetupProposalGenerator", () => {
	it("fails closed without a Mistral key and never calls the completion adapter", async () => {
		const generator = createMeetupProposalGenerator(undefined, { now: () => NOW });

		expect(await generator.generate(validInput)).toBeNull();
		expect(chatComplete).not.toHaveBeenCalled();
	});

	it("rejects input outside the allow-list before any model call", async () => {
		const input = {
			...validInput,
			match_id: "20000000-0000-0000-0000-000000000001",
			preferences: {
				...validInput.preferences,
				first: {
					...validInput.preferences.first,
					constraints: { name: "private", direct_chat_text: "do not send this" },
				},
			},
		} as unknown as ProposalGeneratorInput;
		const generator = createMeetupProposalGenerator("test-key", { now: () => NOW });

		expect(await generator.generate(input)).toBeNull();
		expect(chatComplete).not.toHaveBeenCalled();
	});

	it("passes only the copied scheduling allow-list to Mistral and unwraps its JSON envelope", async () => {
		chatComplete.mockResolvedValueOnce(JSON.stringify({ candidates: validCandidates }));
		const generator = createMeetupProposalGenerator("test-key", { now: () => NOW });

		const result = await generator.generate(validInput);

		expect(result).toEqual(validCandidates);
		expect(chatComplete).toHaveBeenCalledTimes(1);
		const [apiKey, messages, options] = chatComplete.mock.calls[0] as [string, Array<{ role: string; content: string }>, Record<string, unknown>];
		expect(apiKey).toBe("test-key");
		expect(options).toEqual({
			model: "mistral-large-test",
			maxTokens: 1400,
			temperature: 0.2,
			responseFormat: { type: "json_object" },
		});
		expect(messages).toHaveLength(2);
		expect(messages[0].role).toBe("system");
		expect(messages[1].role).toBe("user");
		expect(messages[1].content).toContain('"interaction_dna"');
		expect(messages[1].content).not.toContain("match_id");
		expect(messages[1].content).not.toContain("direct_chat_text");
		expect(messages[1].content).not.toContain("name");
		expect(messages[1].content).toContain(NOW.toISOString());
	});

	it("fails closed for malformed model JSON or an unexpected envelope", async () => {
		const generator = createMeetupProposalGenerator("test-key", { now: () => NOW });

		chatComplete.mockResolvedValueOnce("not-json");
		expect(await generator.generate(validInput)).toBeNull();

		chatComplete.mockResolvedValueOnce(JSON.stringify({ candidates: validCandidates, extra: "not allowed" }));
		expect(await generator.generate(validInput)).toBeNull();
	});

	it("contains no model or parser error details when completion fails", async () => {
		const secretMarker = "PRIVATE_MODEL_RESPONSE";
		chatComplete.mockRejectedValueOnce(new Error(secretMarker));
		const generator = createMeetupProposalGenerator("test-key", { now: () => NOW });

		expect(await generator.generate(validInput)).toBeNull();
	});
});

