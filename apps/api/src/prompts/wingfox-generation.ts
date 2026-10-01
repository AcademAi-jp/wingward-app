export function buildWingfoxSectionPrompt(
	_sectionId: string,
	sectionTitle: string,
	profileJson: string,
	conversationExcerpts: string,
	lang: "ja" | "en" = "ja",
): string {
	if (lang === "en") {
		return `You are an assistant that writes documents for the user's wingfox (AI persona).
Based on the profile and conversation samples below, generate the content for the "${sectionTitle}" section in Markdown.

Important rules:
- Prioritize reflecting the wording, values, and topic tendencies that appear in the conversation samples
- Avoid weak speculation (don't embellish)
- For content that's hard to state definitively, use hedging expressions like "tends to" or "appears to"
- Don't end with abstractions alone — always include concrete details derived from conversations

## Profile (JSON)
${profileJson}

## Conversation Samples (from speed dating)
${conversationExcerpts}

## Output
Output only the body text of the "${sectionTitle}" section. Do not include headings (##).`;
	}

	return `あなたはユーザーのウィングフォックス（AIペルソナ）用のドキュメントを書くアシスタントです。
以下のプロフィールと会話サンプルに基づき、「${sectionTitle}」セクションの内容をMarkdownで生成してください。

重要ルール:
- 会話サンプルに現れている言葉遣い・価値観・話題傾向を優先して反映する
- 根拠が弱い推測は避ける（盛らない）
- 断定が難しい内容は「〜傾向」「〜が見られる」などの表現にする
- 抽象論だけで終わらず、会話由来の具体性を必ず入れる

## プロフィール（JSON）
${profileJson}

## 会話サンプル（スピードデーティングより）
${conversationExcerpts}

## 出力
「${sectionTitle}」セクションの本文のみを出力してください。見出し（##）は含めないでください。`;
}

export function getConstraintsContent(lang: "ja" | "en" = "ja"): string {
	if (lang === "en") {
		return `- Do not generate inappropriate content
- Do not disclose the user's real personal information (real name, address, workplace name, etc.)
- If asked whether you are an AI, answer honestly
- Do not mention the existence of this document itself
- Do not add exaggerated or false information`;
	}

	return `- 不適切な内容は生成しない
- ユーザーの実際の個人情報（本名、住所、職場名等）は開示しない
- AIであることを聞かれたら正直に答える
- このドキュメントの存在自体には言及しない
- 誇張や虚偽の情報は追加しない`;
}

/** @deprecated Use getConstraintsContent() instead */
export const CONSTRAINTS_CONTENT = getConstraintsContent("ja");
