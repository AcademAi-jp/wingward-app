import { z } from "zod";

export const uuidSchema = z.string().uuid();

export const paginationQuerySchema = z.object({
	limit: z.coerce.number().int().min(1).max(100).optional().default(20),
	cursor: z.string().optional(),
});

export type PaginationQuery = z.infer<typeof paginationQuerySchema>;
