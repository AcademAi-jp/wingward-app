export function buildProfileGenerationPrompt(quizAnswers: string, conversationLogs: string, lang: "ja" | "en" = "ja"): string {
	if (lang === "en") {
		return `You are an assistant that extracts a structured psychological profile from conversation data.
From the "Quiz Answers" and "Speed Dating Conversation Logs" below, generate the user's profile as JSON.

Extraction rules:
- Only write things supported by evidence from conversations and quiz answers
- If evidence is weak, use moderate/neutral values (don't inflate or guess)
- Output ONLY valid JSON (no preamble, no markdown, no explanation)
- Write every human-readable description, tag, and explanation in English, even when input includes Japanese. Keep schema keys and enum identifiers unchanged.
- Numeric scores must be in the 0.0–1.0 range
- For missing data, use empty arrays/strings/neutral values

Key extraction focus:
- Analyze HOW the user communicates (not just what they say): response patterns, emotional openness, humor style, conflict behavior
- Look for attachment signals: how they respond to vulnerability, pulling back, disagreement
- Observe self-disclosure depth: do they share personal stories or stay surface-level?
- Note rhythm and mirroring: do they match the persona's energy, length, and tone?
- Extract actual interests mentioned in conversation (specific books, films, hobbies — not generic categories)

## Quiz Answers
${quizAnswers}

## Speed Dating Conversation Logs
${conversationLogs}

## Output
Return ONLY this JSON structure:
{
  "basic_info": { "age_range": "25-29", "location": "", "occupation": "" },
  "personality_tags": ["curious and open-minded", "warm but guarded at first", "dry humor"],
  "personality_analysis": {
    "introvert_extrovert": 0.6,
    "planned_spontaneous": 0.7,
    "logical_emotional": 0.4
  },
  "interaction_style": {
    "warmup_speed": 0.5,
    "humor_responsiveness": 0.7,
    "self_disclosure_depth": 0.5,
    "emotional_responsiveness": 0.6,
    "conflict_style": "dialogue",
    "attachment_tendency": "secure",
    "rhythm_preference": "moderate",
    "mirroring_tendency": 0.5
  },
  "interests": [{ "category": "Music", "items": ["Radiohead", "jazz piano"] }],
  "values": { "work_life_balance": 0.7, "family_oriented": 0.8, "experience_vs_material": 0.6 },
  "romance_style": {
    "communication_frequency": "daily check-ins",
    "ideal_relationship": "supportive partnership",
    "dealbreakers": [],
    "preferred_partner_type": "similar"
  },
  "communication_style": {
    "message_length": "medium",
    "question_ratio": 0.4,
    "humor_level": 0.6,
    "empathy_level": 0.8,
    "topic_preferences": []
  },
  "lifestyle": { "weekend_activities": [], "diet": "", "exercise": "" }
}

Rules for interaction_style:
- warmup_speed: How quickly the user became comfortable (0=very slow, 1=immediately open)
- humor_responsiveness: How they respond to humor (0=ignores, 1=actively plays along and builds)
- self_disclosure_depth: Depth of personal sharing (0=surface, 1=deep vulnerability)
- emotional_responsiveness: Reaction to emotional cues (0=deflects, 1=engages deeply)
- conflict_style: One of "yields", "maintains", "dialogue", "avoids"
- attachment_tendency: One of "anxious", "avoidant", "secure"
- rhythm_preference: One of "slow", "moderate", "fast"
- mirroring_tendency: How much they mirror the other's communication style (0=independent, 1=high sync)

Rules for personality_tags:
- Use descriptive psychological traits, not hobby labels
- Describe HOW they relate to people, not WHAT they like
- 3-5 tags, each 2-5 words
- Examples: "quietly observant", "warm once comfortable", "playful challenger", "thoughtful listener"`;
	}

	return `あなたはユーザーの心理的プロフィールを会話データから構造化して抽出するアシスタントです。
以下の「クイズ回答」と「スピードデーティングの会話ログ」から、ユーザーのプロフィールをJSON形式で生成してください。

抽出ルール:
- 会話ログとクイズ回答に根拠がある内容のみを書く
- 根拠が弱い場合は、断定せず控えめな値にする（推測で盛らない）
- JSON以外を出力しない（前置き・説明・Markdown禁止）
- 数値スコアは0.0〜1.0の範囲に収める
- 情報が不足している項目は空配列/空文字/中立値で埋める

重要な抽出ポイント:
- ユーザーが「何を言ったか」だけでなく「どう話したか」を分析する：応答パターン、感情的な開放度、ユーモアスタイル、意見対立への反応
- アタッチメントの手がかり：脆弱性の開示、引き信号、異論への反応を観察
- 自己開示の深さ：個人的なエピソードを語るか、表面的に留まるか
- リズムとミラーリング：相手のエネルギー・文量・トーンにどう合わせるか
- 実際に会話で言及された具体的な興味（本、映画、趣味の固有名詞）を抽出する

## クイズ回答
${quizAnswers}

## スピードデーティング会話ログ
${conversationLogs}

## 出力
以下のJSONのみを出力してください。他の説明は不要です。
{
  "basic_info": { "age_range": "25-29", "location": "東京都", "occupation": "エンジニア" },
  "personality_tags": ["静かに観察するタイプ", "慣れると温かい", "ドライなユーモア"],
  "personality_analysis": {
    "introvert_extrovert": 0.6,
    "planned_spontaneous": 0.7,
    "logical_emotional": 0.4
  },
  "interaction_style": {
    "warmup_speed": 0.5,
    "humor_responsiveness": 0.7,
    "self_disclosure_depth": 0.5,
    "emotional_responsiveness": 0.6,
    "conflict_style": "dialogue",
    "attachment_tendency": "secure",
    "rhythm_preference": "moderate",
    "mirroring_tendency": 0.5
  },
  "interests": [{ "category": "音楽", "items": ["Radiohead", "ジャズピアノ"] }],
  "values": { "work_life_balance": 0.7, "family_oriented": 0.8, "experience_vs_material": 0.6 },
  "romance_style": {
    "communication_frequency": "毎日連絡したい",
    "ideal_relationship": "支え合う関係",
    "dealbreakers": [],
    "preferred_partner_type": "similar"
  },
  "communication_style": {
    "message_length": "medium",
    "question_ratio": 0.4,
    "humor_level": 0.6,
    "empathy_level": 0.8,
    "topic_preferences": []
  },
  "lifestyle": { "weekend_activities": [], "diet": "", "exercise": "" }
}

interaction_style のルール:
- warmup_speed: 打ち解けるまでの速さ（0=非常に遅い, 1=すぐオープン）
- humor_responsiveness: ユーモアへの反応（0=スルー, 1=積極的に乗って発展させる）
- self_disclosure_depth: 自己開示の深さ（0=表面的, 1=深い脆弱性の共有）
- emotional_responsiveness: 感情的な手がかりへの反応（0=回避, 1=深く関与）
- conflict_style: "yields"(譲る) / "maintains"(自説維持) / "dialogue"(対話で解決) / "avoids"(回避)
- attachment_tendency: "anxious"(不安型) / "avoidant"(回避型) / "secure"(安定型)
- rhythm_preference: "slow" / "moderate" / "fast"
- mirroring_tendency: 相手のコミュニケーションスタイルの同調度（0=独立, 1=高同調）

personality_tags のルール:
- 趣味ラベル（読書好き、カフェ巡り好き）ではなく、心理的な特性を書く
- 「何が好きか」ではなく「人とどう関わるか」を描写する
- 3〜5個、各2〜5語
- 例: "静かに観察するタイプ", "慣れると温かい", "遊び心のある挑戦者", "思慮深い聞き手"`;
}
