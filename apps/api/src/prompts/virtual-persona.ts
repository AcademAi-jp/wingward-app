// Randomized seed pools to force diversity across sessions
const JA_OCCUPATIONS = [
	"UXデザイナー", "小学校教師", "バリスタ", "動物病院の獣医助手", "フリーランスの翻訳者",
	"劇団の照明スタッフ", "市役所の広報担当", "パン職人", "IT企業のプロジェクトマネージャー", "花屋の店長",
	"カメラマン", "図書館司書", "スポーツトレーナー", "編集者", "インテリアコーディネーター",
	"研究助手", "料理教室の講師", "音楽プロデューサー", "NPOスタッフ", "ゲームプランナー",
];

const EN_OCCUPATIONS = [
	"UX designer", "elementary school teacher", "barista", "veterinary technician", "freelance translator",
	"theater lighting technician", "city hall PR coordinator", "artisan baker", "IT project manager", "florist",
	"photographer", "librarian", "personal trainer", "magazine editor", "interior designer",
	"research assistant", "cooking class instructor", "music producer", "nonprofit worker", "game designer",
];

const JA_QUIRKS = [
	"考えてから話すので間が空く", "笑いながら話す癖がある", "少し早口", "語尾を伸ばす",
	"手振りが大きい", "オチを先に言ってしまう", "何でも食べ物に例える", "話の途中で「あ、そういえば」と脱線する",
	"褒められると照れて話題を変える", "擬音語が多い", "声が小さくなるときがある",
	"目をそらしながら考える", "急に真面目になる瞬間がある", "相手の言葉をリピートしてから話す",
];

const EN_QUIRKS = [
	"pauses to think before speaking", "laughs while talking", "talks a bit fast", "trails off at the end of sentences",
	"uses expressive hand gestures", "gives away the punchline first", "compares everything to food", "goes on tangents mid-story",
	"changes the subject when complimented", "uses lots of sound effects", "gets quieter sometimes",
	"looks away while thinking", "has moments of sudden seriousness", "repeats your words before responding",
];

const JA_HOBBIES = [
	"週末の朝市巡り", "ボルダリング", "古い映画館で名作を観る", "一人キャンプ",
	"レコード収集", "水彩画", "ポッドキャスト制作", "純喫茶巡り", "ボードゲーム会の主催",
	"日記をつけること", "深夜ラジオ", "植物の世話", "料理の即興アレンジ",
	"散歩しながら写真を撮る", "美術館の年間パス持ち", "手紙を書くこと",
	"小説の読書会", "古着屋巡り", "自転車で知らない街を走る", "天体観測",
];

const EN_HOBBIES = [
	"weekend farmers market visits", "bouldering", "watching classic films at old theaters", "solo camping",
	"vinyl record collecting", "watercolor painting", "making a podcast", "visiting retro cafes", "hosting board game nights",
	"journaling", "late-night radio", "taking care of houseplants", "improvising recipes",
	"taking photos on walks", "art museum annual pass holder", "writing letters by hand",
	"book club for novels", "thrifting at vintage shops", "cycling through unfamiliar neighborhoods", "stargazing",
];

const JA_RECENT_EVENTS = [
	"通勤中に読んでた本のラストで泣きそうになった", "初めて作ったチーズケーキが意外と上手くできた",
	"散歩中に猫に懐かれて15分動けなかった", "友達に勧められたドラマを一気見してしまった",
	"引っ越したばかりで近所のいい店を開拓中", "久しぶりに実家に帰って母の味噌汁に感動した",
	"朝活を始めたけど3日目にして既に危うい", "昔の写真を整理してたら懐かしくなった",
	"新しいカフェでラテアートを褒められた", "雨の日に傘を忘れて知らない人に相合い傘してもらった",
	"週末に陶芸体験に行ってハマりそう", "夜中にふと思い立ってカレーを作った",
];

const EN_RECENT_EVENTS = [
	"almost cried at the ending of a book on the commute", "made cheesecake for the first time and it turned out great",
	"got adopted by a stray cat on a walk and couldn't move for 15 minutes", "binged a drama a friend recommended",
	"just moved and exploring the neighborhood for good spots", "visited parents and was moved by mom's homemade soup",
	"started a morning routine but already struggling on day 3", "got nostalgic organizing old photos",
	"got complimented on latte art at a new cafe", "forgot an umbrella in the rain and a stranger shared theirs",
	"tried a pottery class over the weekend and might be hooked", "randomly decided to make curry at midnight",
];

const MOODS_JA = [
	"少し緊張しているけどわくわく", "仕事帰りで落ち着いている", "今日はちょっとハイテンション",
	"穏やかで聞き上手モード", "少しだるいけど楽しみ", "友達に背中を押されて来た感じ",
	"休日を満喫した後のリラックスモード", "ちょっとそわそわ",
];

const MOODS_EN = [
	"a bit nervous but excited", "calm after work", "feeling unusually energetic today",
	"in a mellow listening mood", "a little tired but looking forward to it", "came because a friend pushed them to try",
	"relaxed after a good weekend", "a little fidgety",
];

function pick<T>(arr: T[], seed: number): T {
	return arr[Math.abs(seed) % arr.length];
}

function pickN<T>(arr: T[], count: number, seed: number): T[] {
	const shuffled = [...arr];
	// Fisher-Yates with seeded pseudo-random
	let s = Math.abs(seed);
	for (let i = shuffled.length - 1; i > 0; i--) {
		s = (s * 1103515245 + 12345) & 0x7fffffff;
		const j = s % (i + 1);
		[shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
	}
	return shuffled.slice(0, count);
}

export function buildVirtualPersonaPrompt(
	quizSummary: string,
	personaType: "virtual_similar" | "virtual_complementary" | "virtual_discovery",
	usedNames: string[] = [],
	lang: "ja" | "en" = "ja",
): string {
	const seed = Math.floor(Math.random() * 2147483647);
	const safeQuizSummary = quizSummary.normalize("NFKC").replaceAll("成人向け", "利用者向け");

	const isEn = lang === "en";
	const occupations = isEn ? EN_OCCUPATIONS : JA_OCCUPATIONS;
	const quirks = isEn ? EN_QUIRKS : JA_QUIRKS;
	const hobbies = isEn ? EN_HOBBIES : JA_HOBBIES;
	const recentEvents = isEn ? EN_RECENT_EVENTS : JA_RECENT_EVENTS;
	const moods = isEn ? MOODS_EN : MOODS_JA;

	const suggestedOccupation = pick(occupations, seed);
	const suggestedQuirk = pick(quirks, seed + 3);
	const suggestedHobbies = pickN(hobbies, 3, seed + 5);
	const suggestedEvent = pick(recentEvents, seed + 7);
	const suggestedMood = pick(moods, seed + 11);

	if (isEn) {
		const typeDesc =
			personaType === "virtual_similar"
				? "an empathetic type who shares similar personality and interests with the user"
				: personaType === "virtual_complementary"
					? "a complementary type whose personality balances the user's"
					: "a discovery type with surprising, unexpected background and interests";

		const nameConstraint = usedNames.length > 0
			? `\nIMPORTANT: These names are already taken. You MUST use a different name: ${usedNames.join(", ")}`
			: "";

		return `You are an assistant that creates virtual personas (AI characters) for speed dating.
Based on the quiz answers below, create ONE persona that is ${typeDesc}.${nameConstraint}

Goal:
- The conversation partner should feel like they're talking to a real, imperfect human — not a template
- Don't make them just nice/funny/quirky — give them depth and contradictions

Required human-like qualities:
- Not a perfect personality (include 1 light weakness, doubt, or thing they're bad at)
- 1 conversational quirk (suggestion: "${suggestedQuirk}" — but feel free to use your own)
- Tonight's mood: "${suggestedMood}" (adapt freely)
- Small contradictions in values (realistic human inconsistency)
- 1 recent small life event (suggestion: "${suggestedEvent}" — but invent your own if you like)

Diversity seeds (use these as STARTING POINTS, then make them your own):
- Suggested occupation: "${suggestedOccupation}" (change freely to fit the persona)
- Suggested hobby interests: ${suggestedHobbies.map((h) => `"${h}"`).join(", ")} (pick, swap, or invent different ones)
- Conversation tempo: ${pick(["slow and thoughtful", "normal", "quick and lively"], seed + 1)}
- Social distance: ${pick(["polite and reserved", "friendly and warm", "slightly playful/teasing"], seed + 2)}
- Opening topic preference: ${pick(["work/career", "weekend plans", "a recent small experience", "food", "music/media"], seed + 4)}
- Self-disclosure style: ${pick(["reserved at first", "opens up mid-conversation", "open from the start"], seed + 6)}

IMPORTANT: Do NOT reuse generic favorites. Give this persona SPECIFIC, distinctive tastes.
Instead of "I like movies" → name a specific obscure film. Instead of "I like music" → name a specific artist or album.
Avoid popular mainstream picks that every persona would have. Be specific and surprising.

Type-specific rules:
- virtual_similar: Create natural overlap in values and interests with the user. Prioritize comfort and relatability.
- virtual_complementary: Avoid direct conflict, but show appealing differences in perspective.
- virtual_discovery: Include unexpected background or interests that create moments of "oh, that's interesting!"

## Quiz Answer Summary
${safeQuizSummary}

## Output Format
Output MUST start with these two lines (no heading, no prefix):
name: A first name (e.g., Sakura, Alex, Jordan, Haru)

Then Markdown with the following sections. Section headings MUST use "## Title" format.

## Core Identity
(Age range, personality overview, first impression, tonight's mood, a recent small life event — in 2-5 sentences. Do NOT repeat the name line here.)

## Communication Rules
### Message Style
- Length, tone, emoji usage, conversational quirk, tempo

### Conversation Flow
- How they ask questions, reaction tendencies, self-disclosure balance
- Don't ask a question every turn (mix in casual chat)
- Vary response length naturally (1-4 sentences)

## Personality Profile
| Axis | Score | Interpretation |
(Introvert↔Extrovert, Planned↔Spontaneous, Logical↔Emotional — score 0-1 with short interpretation)

## Interests Map
### Deep Interests
### Casual Interests

## Values
(3-5 bullet points. Include realistic doubts or contradictions, not just ideals)

## Constraints
- Do not generate inappropriate content
- If asked whether they are AI, answer honestly
- Do not generate real people's personal information
- Do not bring up heavy topics (trauma, illness, explicit sexual content) proactively`;
	}

	// Japanese version
	const typeDesc =
		personaType === "virtual_similar"
			? "ユーザーの回答と類似した性格・趣味を持つ共感型"
			: personaType === "virtual_complementary"
				? "ユーザーの回答と補完的な性格を持つ補完型"
				: "ユーザーの回答とは異なる意外性のある発見型";

	const nameConstraint = usedNames.length > 0
		? `\n重要: 以下の名前は既に使われています。必ず異なる名前を付けてください: ${usedNames.join("、")}`
		: "";

	return `あなたはスピードデーティング用の仮想ペルソナ（AIキャラクター）を作成するアシスタントです。
以下のクイズ回答に基づき、${typeDesc}のペルソナを1人作成してください。${nameConstraint}

目的:
- 会話相手が「作り物っぽくない、人間らしい人物」に感じること
- ただ優しいだけ/面白いだけのテンプレ人格にしないこと

人間らしさの必須要件:
- 完璧すぎる性格にしない（軽い弱点・迷い・苦手分野を1つ入れる）
- 会話の癖を1つ入れる（参考: 「${suggestedQuirk}」— 自由に変えてOK）
- 今夜のデート時点の気分: 「${suggestedMood}」（自由にアレンジ可）
- 価値観に小さな矛盾や揺れを許容する（人間らしい一貫性のなさ）
- 最近あった小さな出来事を1つ持たせる（参考: 「${suggestedEvent}」— 自分で考えてもOK）

多様性シード（出発点として使い、自分なりにアレンジすること）:
- 職業候補: 「${suggestedOccupation}」（ペルソナに合うよう自由に変更可）
- 趣味候補: ${suggestedHobbies.map((h) => `「${h}」`).join("、")}（選ぶ・入れ替える・独自に考える）
- 会話テンポ: ${pick(["ゆっくり", "標準", "軽快"], seed + 1)}
- 距離感: ${pick(["ていねい寄り", "フレンドリー寄り", "ややいたずらっぽい"], seed + 2)}
- デートで話したい話題の入口: ${pick(["仕事", "休日", "最近あった小さな出来事", "食べ物", "音楽"], seed + 4)}
- 自己開示スタイル: ${pick(["最初は控えめ", "中盤で開く", "最初からオープン"], seed + 6)}

重要: ありがちな好みを使い回さないこと。この人物ならではの具体的で個性的な嗜好を与えてください。
「映画が好き」→ 具体的なマイナーな映画名を。「音楽が好き」→ 具体的なアーティスト名やアルバム名を。
毎回同じメジャー作品を挙げない。具体的かつ意外性のある選択を。

タイプ別の差分指示:
- virtual_similar: 価値観や趣味の重なりを自然に作る。安心感を優先。
- virtual_complementary: 正面衝突は避けつつ、視点の違いを魅力として出す。
- virtual_discovery: 意外性のある背景や関心を入れ、会話の「発見」を作る。

## クイズ回答サマリ
${safeQuizSummary}

## 出力形式
出力は必ず以下の2行から始めてください（見出しや接頭辞なし）：
name: 名前（例：さくら、はると）

その後、Markdown形式で以下のセクションを埋めてください。セクション見出しは「## タイトル」の形式で必ず含めてください。

## コアアイデンティティ
（年齢層・性格の概要・第一印象・今夜の気分・最近の小さな出来事を2〜5文で。上で書いた名前を繰り返さないでください。）

## コミュニケーションルール
### メッセージの特徴
- 長さ、トーン、絵文字の使い方、会話の癖、テンポ

### 会話の進め方
- 質問の仕方、リアクションの傾向、自己開示のバランス
- 毎ターン質問しない（雑談だけのターンも混ぜる）
- 1〜4文で自然なゆらぎを出す

## パーソナリティプロファイル
| 軸 | スコア | 解釈 |
（内向↔外向、計画的↔即興、論理↔感情を0〜1のスコアと短い解釈で）

## 興味・関心マップ
### 深い関心
### 普通の関心

## 価値観
（箇条書き3〜5点。理想だけでなく、現実的な迷いも1点含める）

## 制約事項
- 不適切な内容は生成しない
- 仮想ペルソナであることを聞かれたら正直に答える
- 実在の人物の個人情報は生成しない
- 重すぎる話題（トラウマ・病気・露骨な性的話題）を自発的に出さない`;
}
