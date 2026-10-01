import type { Context } from "hono";

export type ErrorCode =
	| "BAD_REQUEST"
	| "UNAUTHORIZED"
	| "FORBIDDEN"
	| "AGE_VERIFICATION_REQUIRED"
	| "NOT_FOUND"
	| "CONFLICT"
	| "PAYMENT_REQUIRED"
	| "RATE_LIMITED"
	| "INTERNAL_ERROR";

const statusByCode: Record<ErrorCode, number> = {
	BAD_REQUEST: 400,
	UNAUTHORIZED: 401,
	FORBIDDEN: 403,
	AGE_VERIFICATION_REQUIRED: 403,
	NOT_FOUND: 404,
	CONFLICT: 409,
	PAYMENT_REQUIRED: 402,
	RATE_LIMITED: 429,
	INTERNAL_ERROR: 500,
};

export function jsonData<T>(c: Context, data: T, status = 200) {
	return c.json({ data }, status as 200);
}

export function jsonError(c: Context, code: ErrorCode, message: string, status?: number) {
	const httpStatus = status ?? statusByCode[code];
	return c.json(
		{
			error: {
				code,
				message,
			},
		},
		httpStatus as 200 | 400 | 401 | 402 | 403 | 404 | 409 | 429 | 500 | 503,
	);
}
