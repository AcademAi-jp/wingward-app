/** FOX同士の会話で1発話に許す最大文字数（トークン切れ防止） */
export const FOX_MESSAGE_MAX_CHARS = 100;

/**
 * 指定文字数以内に収める。可能なら句点（。．.）で区切って完結した文にする。
 */
export function truncateFoxMessage(text: string): string {
	const t = text.trim();
	if (t.length <= FOX_MESSAGE_MAX_CHARS) return t;
	const slice = t.slice(0, FOX_MESSAGE_MAX_CHARS + 1);
	const last =
		Math.max(
			slice.lastIndexOf("。"),
			slice.lastIndexOf("．"),
			slice.lastIndexOf("."),
		) + 1;
	if (last > FOX_MESSAGE_MAX_CHARS * 0.5) {
		return slice.slice(0, last).trim();
	}
	return slice.slice(0, FOX_MESSAGE_MAX_CHARS).trim();
}
