export const DEFAULT_LIMIT = 20;
export const MAX_LIMIT = 100;

export function parseLimit(raw: string | undefined): number {
	const n = raw ? Number.parseInt(raw, 10) : DEFAULT_LIMIT;
	if (Number.isNaN(n) || n < 1) return DEFAULT_LIMIT;
	return Math.min(n, MAX_LIMIT);
}

export function parseCursor(raw: string | undefined): string | null {
	if (!raw || typeof raw !== "string") return null;
	return raw;
}

export type PageResult<T> = {
	data: T[];
	next_cursor: string | null;
	has_more: boolean;
};
