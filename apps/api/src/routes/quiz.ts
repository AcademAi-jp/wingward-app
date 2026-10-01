import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { z } from "zod";

const quiz = new Hono<Env>();

const requiredQuestionIds = new Set(Array.from({ length: 10 }, (_, index) => `q${index + 1}`));
const allowedSelectionValues = new Set(["a", "b", "c", "d"]);

const postAnswersSchema = z.object({
	answers: z.array(
		z.object({
			question_id: z.string().min(1).max(80),
			selected: z.array(z.string().min(1).max(120)).min(1).max(4),
		}).strict(),
	).min(1).max(10),
}).strict();

/** GET /api/quiz/questions - list all quiz questions */
quiz.get("/questions", requireAuth, async (c) => {
	const supabase = getSupabaseClient(c.env);
	const { data, error } = await supabase
		.from("quiz_questions")
		.select("id, category, allow_multiple, sort_order")
		.order("sort_order", { ascending: true });
	if (error) {
		console.error("[quiz/questions] lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch questions");
	}
	return jsonData(c, data ?? []);
});

/** POST /api/quiz/answers - submit answers (UPSERT). Sets onboarding_status to quiz_completed only when not already confirmed (edit mode). */
quiz.post("/answers", requireAuth, async (c) => {
	let requestBody: unknown;
	try {
		requestBody = await c.req.json();
	} catch {
		return jsonError(c, "BAD_REQUEST", "Invalid quiz answers");
	}

	const parsed = postAnswersSchema.safeParse(requestBody);
	if (!parsed.success) {
		return jsonError(c, "BAD_REQUEST", "Invalid quiz answers");
	}
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);

	// The supported iOS and web catalogs contain exactly q1-q10. Fail closed if
	// the database catalog drifts from that contract or changes selection mode.
	const { data: questions, error: questionsError } = await supabase
		.from("quiz_questions")
		.select("id, allow_multiple");
	if (questionsError || !questions) {
		console.error("[quiz/answers] question lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to validate answers");
	}
	const questionIds = new Set(questions.map((question) => question.id));
	if (
		questions.length !== requiredQuestionIds.size ||
		questionIds.size !== requiredQuestionIds.size ||
		[...requiredQuestionIds].some((questionId) => !questionIds.has(questionId)) ||
		questions.some((question) => question.allow_multiple !== false)
	) {
		console.error("[quiz/answers] question catalog mismatch");
		return jsonError(c, "INTERNAL_ERROR", "Failed to validate answers");
	}

	const seenQuestionIds = new Set<string>();
	for (const { question_id, selected } of parsed.data.answers) {
		if (!requiredQuestionIds.has(question_id) || !questionIds.has(question_id) || seenQuestionIds.has(question_id)) {
			return jsonError(c, "BAD_REQUEST", "Invalid quiz answers");
		}
		seenQuestionIds.add(question_id);

		const selectedValues = new Set<string>();
		for (const value of selected) {
			if (
				value.trim().length === 0 ||
				!allowedSelectionValues.has(value) ||
				selectedValues.has(value)
			) {
				return jsonError(c, "BAD_REQUEST", "Invalid quiz answers");
			}
			selectedValues.add(value);
		}

		// Every supported question is single-choice.
		if (selected.length !== 1) {
			return jsonError(c, "BAD_REQUEST", "Invalid quiz answers");
		}
	}
	if (seenQuestionIds.size !== requiredQuestionIds.size) {
		return jsonError(c, "BAD_REQUEST", "Invalid quiz answers");
	}

	// Read the profile before writing answers so a profile read failure cannot
	// leave a partial submission behind.
	const { data: profile, error: profileError } = await supabase
		.from("user_profiles")
		.select("onboarding_status")
		.eq("id", userId)
		.single();
	if (profileError || !profile) {
		console.error("[quiz/answers] profile lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to load onboarding status");
	}

	const answerRows = parsed.data.answers.map(({ question_id, selected }) => ({
		user_id: userId,
		question_id,
		selected,
	}));
	const { error: answerError } = await supabase
		.from("quiz_answers")
		.upsert(answerRows, { onConflict: "user_id,question_id" });
	if (answerError) {
		console.error("[quiz/answers] answer save failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to save answers");
	}

	// Only update onboarding_status when not already confirmed (edit flow must not revert status).
	const currentStatus = profile.onboarding_status ?? "not_started";
	if (currentStatus !== "confirmed") {
		const { error: onboardingError } = await supabase
			.from("user_profiles")
			.update({ onboarding_status: "quiz_completed", updated_at: new Date().toISOString() })
			.eq("id", userId)
			.neq("onboarding_status", "confirmed");
		if (onboardingError) {
			console.error("[quiz/answers] onboarding update failed");
			return jsonError(c, "INTERNAL_ERROR", "Failed to update onboarding status");
		}
	}

	return jsonData(c, { message: "Answers saved", count: answerRows.length });
});

/** GET /api/quiz/answers - get my answers */
quiz.get("/answers", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { data, error } = await supabase
		.from("quiz_answers")
		.select("question_id, selected")
		.eq("user_id", userId);
	if (error) {
		console.error("[quiz/answers] lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch answers");
	}
	return jsonData(c, data ?? []);
});

export default quiz;
