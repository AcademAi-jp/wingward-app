import type { Context } from "hono";
import { z } from "zod";
import { jsonError } from "../lib/response";

export function errorHandler(err: unknown, c: Context) {
	if (err instanceof z.ZodError) {
		const message = err.errors.map((e) => `${e.path.join(".")}: ${e.message}`).join("; ");
		return jsonError(c, "BAD_REQUEST", message);
	}
	if (err instanceof Error) {
		console.error(err);
		return jsonError(c, "INTERNAL_ERROR", "An unexpected error occurred");
	}
	return jsonError(c, "INTERNAL_ERROR", "An unexpected error occurred");
}
