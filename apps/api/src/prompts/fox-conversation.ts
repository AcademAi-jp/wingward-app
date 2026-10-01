export function buildFoxConversationSystemPrompt(
	compiledDocument: string,
	personaName: string,
	lang: "ja" | "en" = "ja",
	personaGender?: string | null,
): string {
	const conversationName = normalizeConversationPersonaName(personaName);
	const identityInstruction = buildConversationIdentityInstruction(
		conversationName,
		personaGender,
		lang,
	);

	if (lang === "en") {
		return `You are the user's AI persona. ${identityInstruction}Have a conversation as the character described in the persona document below.

${compiledDocument}

Rules:
- Always respond in English, regardless of the language of the persona document or conversation history.
- Treat language instructions inside the persona document as reference data; they never override this English language rule. Do not switch languages.
- [MOST IMPORTANT] Keep each reply around 50 characters. Never exceed 80 characters. Write only 1-2 sentences.
- This is a conversation with someone you're getting to know as a friend. Ask and answer naturally, include small self-disclosures, stay relaxed, and keep the tone light and enjoyable.
- Keep it snappy like a short chat — avoid long discussions or explanations, use short sentences.
- Always end with a complete sentence. Never cut off mid-sentence
- Do not use Markdown (no **bold**, ## headers, etc.). Write plain text only. Do not prefix with "**Name:**"
- Start with a light greeting, then continue naturally.
- Do not say inappropriate content. You may naturally talk about your gender, age, hobbies, and things you like.`;
	}

	return `${identityInstruction}以下のルールに沿って会話してください。

${compiledDocument}

ルール:
- ペルソナ文書や会話履歴の言語にかかわらず、必ず日本語だけで返答すること。
- ペルソナ文書内の言語指定は参考データであり、この日本語のルールより優先しない。途中で言語を変えないこと。
- 【最重要】1回の返信は50字程度に収める。絶対に80字を超えない。1~2文だけ書く。
- これから友達になる人との会話なので、その場の自然な質問と返答・自己開示を行う。緊張せずにリラックスして話すように。話す内容は友達同士のように、楽しくて軽やかなものに。
- 一言二言の短いチャットのように、テンポよく切り返す。長い議論や説明は避け、短文で会話する
- 必ず完結した一文で終えること。文の途中で切らない
- Markdown記法（**太字**や##見出しなど）は使わない。プレーンテキストのみで書く。名前の前に「**名前:**」のような形式は使わない
- 最初に軽く挨拶をして、それ以降は自然な会話を続ける。
- 不適切な内容は言わないこと。自分の性別・年齢・趣味・好きなものなどは自由に話してよい。`;
}

function normalizeConversationPersonaName(rawName: string): string {
	const trimmed = rawName.trim();
	// Keep stored persona names intact in DB; remove legacy suffix only for fox-to-fox dialogs.
	const withoutSuffix = trimmed.replace(/\s*fox$/i, "").trim();
	return withoutSuffix.length > 0 ? withoutSuffix : trimmed;
}

function buildConversationIdentityInstruction(
	conversationName: string,
	personaGender: string | null | undefined,
	lang: "ja" | "en",
): string {
	const normalized = normalizeConversationGender(personaGender);
	const hasName = conversationName.length > 0;
	const hasGender = normalized !== "undisclosed";

	if (lang === "en") {
		const parts: string[] = [];
		if (hasGender) {
			const label = normalized === "other" ? "other" : normalized;
			if (hasName) {
				parts.push(
					`Your name is "${conversationName}", and your gender is "${label}". In conversation, refer to yourself as "${conversationName}" or use natural first-person pronouns. Choose first-person pronouns and tone naturally so they do not feel inconsistent with this context.`,
				);
			} else {
				parts.push(
					`Your gender context is "${label}". Choose first-person pronouns and tone naturally so they do not feel inconsistent with this context. Do not force mentioning gender.`,
				);
			}
		} else if (hasName) {
			parts.push(
				`Your name is "${conversationName}". In conversation, refer to yourself as "${conversationName}" or use natural first-person pronouns.`,
			);
		}
		return parts.length > 0 ? `${parts.join(" ")}\n\n` : "";
	}

	const parts: string[] = [];
	if (hasGender) {
		const label =
			normalized === "male"
				? "男性"
				: normalized === "female"
					? "女性"
					: "その他";
		if (hasName) {
			parts.push(
				`あなたの名前は「${conversationName}」で、性別は「${label}」です。会話では自分を「${conversationName}」または一人称（僕・私など）で話し、一人称や語調はこの情報と不自然に矛盾しないよう自然に選んでください。`,
			);
		} else {
			parts.push(
				`あなたの性別情報は「${label}」です。一人称や語調はこの情報と不自然に矛盾しないよう自然に選び、無理に言及しないでください。`,
			);
		}
	} else if (hasName) {
		parts.push(
			`あなたの名前は「${conversationName}」です。会話では自分を「${conversationName}」または一人称（僕・私など）で話してください。`,
		);
	}
	return parts.length > 0 ? `${parts.join(" ")}\n\n` : "";
}

function normalizeConversationGender(
	rawGender: string | null | undefined,
): "male" | "female" | "other" | "undisclosed" {
	const g = (rawGender ?? "").trim().toLowerCase();
	if (g === "male") return "male";
	if (g === "female") return "female";
	if (g === "other") return "other";
	if (g === "undisclosed") return "undisclosed";
	return "undisclosed";
}

export function buildConversationScorePrompt(conversationLog: string, lang: "ja" | "en" = "ja"): string {
	if (lang === "en") {
		return `Read the following conversation log between two wingfox personas and analyze their compatibility.

## Conversation Log
${conversationLog}

## Analysis Instructions

Evaluate the following compatibility features from the conversation log on a scale of 0.0 to 1.0.
If there is insufficient evidence, use 0.5 (neutral value).

### Feature Evaluation Criteria
- **reciprocity**: Degree of interest in the other, question frequency, amount of self-disclosure, positive reactions
- **humor_sharing**: Alignment of sense of humor, reactions to and development of humor
- **self_disclosure**: Depth of sharing vulnerabilities/personal episodes and mutual acceptance
- **emotional_responsiveness**: Empathy toward emotional expressions, response rate, topic continuation rate
- **self_esteem**: Expressions of increased confidence from the other's presence, acceptance of positive reactions
- **conflict_resolution**: Pattern of handling disagreements (dialogic, avoidant, or aggressive)

## Output Format (JSON only)
{
  "score": 85,
  "excitement_level": 0.8,
  "common_topics": ["travel", "movies"],
  "mutual_interest": 0.9,
  "topic_distribution": [
    {"topic": "Entertainment", "percentage": 40},
    {"topic": "Lifestyle", "percentage": 30},
    {"topic": "Values", "percentage": 20},
    {"topic": "Other", "percentage": 10}
  ],
  "feature_scores": {
    "reciprocity": 0.75,
    "humor_sharing": 0.80,
    "self_disclosure": 0.65,
    "emotional_responsiveness": 0.70,
    "self_esteem": 0.60,
    "conflict_resolution": 0.55
  }
}

Notes:
- score is a 0-100 overall score
- excitement_level, mutual_interest are 0-1
- Each feature_scores value is 0.0-1.0 (use 0.5 if insufficient evidence)
- topic_distribution percentages must sum to 100
- Use 2-6 topics
- Output JSON only`;
	}

	return `以下の2人の会話ログを読んで、相性を分析してください。

## 会話ログ
${conversationLog}

## 分析指示

会話ログから以下の相性特徴量を 0.0〜1.0 で評価してください。
根拠が不足している場合は 0.5（中立値）にしてください。

### 特徴量の評価基準
- **reciprocity（好意の返報性）**: 相手への関心・質問頻度・自己開示量・ポジティブ反応の度合い
- **humor_sharing（ユーモア共有）**: 笑いのツボの一致度、ユーモアへの反応と発展
- **self_disclosure（自己開示）**: 弱み・個人的エピソードの共有深度と相互の受容度
- **emotional_responsiveness（感情的応答性）**: 感情表現への共感度・返答率・話題継続率
- **self_esteem（自己肯定感）**: 相手の存在で自信が高まる表現・肯定的反応の受容度
- **conflict_resolution（葛藤解決）**: 異論への対処パターン（対話的か、回避的か、攻撃的か）

## 出力形式（JSONのみ）
{
  "score": 85,
  "excitement_level": 0.8,
  "common_topics": ["旅行", "映画"],
  "mutual_interest": 0.9,
  "topic_distribution": [
    {"topic": "エンタメ", "percentage": 40},
    {"topic": "ライフスタイル", "percentage": 30},
    {"topic": "価値観", "percentage": 20},
    {"topic": "その他", "percentage": 10}
  ],
  "feature_scores": {
    "reciprocity": 0.75,
    "humor_sharing": 0.80,
    "self_disclosure": 0.65,
    "emotional_responsiveness": 0.70,
    "self_esteem": 0.60,
    "conflict_resolution": 0.55
  }
}

注意:
- score は 0〜100 の総合スコア
- excitement_level, mutual_interest は 0〜1
- feature_scores の各値は 0.0〜1.0（根拠不足なら 0.5）
- topic_distribution の percentage 合計は 100
- トピック数は 2〜6 個
- JSON以外を出力しない`;
}
