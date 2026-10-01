/**
 * One bounded cleanup pass on the existing 15-minute maintenance tick.
 * Database TTL is 30 minutes; healthy scheduling normally deletes by the next
 * tick (up to about 45 minutes after consent). Failures/backlogs delay deletion.
 * Never log a private input, database error, or exception message.
 */
type JanitorClient = {
	rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }>;
};

export async function pruneMeetupPrivateInputs(client: JanitorClient): Promise<number> {
	try {
		const result = await client.rpc("prune_chat_meetup_private_inputs", {});
		if (result.error || !Array.isArray(result.data) || result.data.length !== 1) {
			throw new Error("invalid cleanup result");
		}
		const row = result.data[0];
		if (!row || typeof row !== "object" || Object.keys(row).length !== 1 ||
			!("pruned" in row) || typeof row.pruned !== "number" ||
			!Number.isInteger(row.pruned) || row.pruned < 0 || row.pruned > 500) {
			throw new Error("invalid cleanup result");
		}
		return row.pruned;
	} catch {
		console.error("[meetup-private-input-janitor] Private input cleanup unavailable");
		return 0;
	}
}
