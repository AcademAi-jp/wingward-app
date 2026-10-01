-- Seed: quiz_questions (12 questions) and persona_section_definitions (8 sections)

INSERT INTO public.quiz_questions (id, category, question_text, options, allow_multiple, sort_order) VALUES
('q1_weekend', '性格', '週末の理想的な過ごし方は？', '[
  {"value": "friends", "label": "友達と外出"},
  {"value": "home", "label": "家でのんびり"},
  {"value": "explore", "label": "新しい場所を探索"},
  {"value": "sports", "label": "スポーツや運動"}
]'::jsonb, false, 1),
('q2_travel', '性格', '旅行の計画はどう立てる？', '[
  {"value": "detailed", "label": "きっちり計画"},
  {"value": "rough_plan", "label": "ざっくり決めてあとは自由"},
  {"value": "no_plan", "label": "完全ノープラン"},
  {"value": "delegate", "label": "誰かに任せる"}
]'::jsonb, false, 2),
('q3_contact', 'コミュニケーション', '友達との連絡頻度は？', '[
  {"value": "daily", "label": "毎日やり取り"},
  {"value": "weekly", "label": "週に数回"},
  {"value": "when_needed", "label": "用事がある時だけ"},
  {"value": "sns_only", "label": "SNSで十分"}
]'::jsonb, false, 3),
('q4_indoor', '趣味', '好きなインドア趣味は？（複数選択可）', '[
  {"value": "movie", "label": "映画・ドラマ"},
  {"value": "reading", "label": "読書"},
  {"value": "game", "label": "ゲーム"},
  {"value": "cooking", "label": "料理"},
  {"value": "music", "label": "音楽"},
  {"value": "none", "label": "なし"}
]'::jsonb, true, 4),
('q5_outdoor', '趣味', '好きなアウトドア趣味は？（複数選択可）', '[
  {"value": "sports", "label": "スポーツ"},
  {"value": "travel", "label": "旅行"},
  {"value": "camp", "label": "キャンプ"},
  {"value": "cafe", "label": "カフェ巡り"},
  {"value": "walk", "label": "散歩"},
  {"value": "none", "label": "なし"}
]'::jsonb, true, 5),
('q6_work_life', '価値観', '仕事とプライベート、大切にしたいのは？', '[
  {"value": "work", "label": "仕事重視"},
  {"value": "private", "label": "プライベート重視"},
  {"value": "balance", "label": "バランス型"},
  {"value": "depends", "label": "その時々で変わる"}
]'::jsonb, false, 6),
('q7_future', '価値観', '将来的に大切にしたいことは？', '[
  {"value": "family", "label": "家族との時間"},
  {"value": "career", "label": "キャリア"},
  {"value": "hobby", "label": "趣味の充実"},
  {"value": "contribution", "label": "社会貢献"}
]'::jsonb, false, 7),
('q8_relationship', '恋愛観', '理想の関係性は？', '[
  {"value": "together", "label": "いつも一緒"},
  {"value": "distance", "label": "適度な距離感"},
  {"value": "independent", "label": "お互い自立"},
  {"value": "situation", "label": "状況による"}
]'::jsonb, false, 8),
('q9_partner', '恋愛観', 'パートナーに一番求めるものは？', '[
  {"value": "kindness", "label": "優しさ"},
  {"value": "humor", "label": "ユーモア"},
  {"value": "intelligence", "label": "知性"},
  {"value": "common_interest", "label": "共通の趣味"},
  {"value": "stability", "label": "安定感"}
]'::jsonb, false, 9),
('q10_diet', 'ライフスタイル', '食事のこだわりは？', '[
  {"value": "cook", "label": "自炊派"},
  {"value": "eat_out", "label": "外食派"},
  {"value": "no_preference", "label": "こだわりなし"},
  {"value": "health", "label": "健康志向"}
]'::jsonb, false, 10),
('q11_age', '基本情報', '年齢層は？', '[
  {"value": "20-24", "label": "20-24"},
  {"value": "25-29", "label": "25-29"},
  {"value": "30-34", "label": "30-34"},
  {"value": "35-39", "label": "35-39"},
  {"value": "40+", "label": "40+"}
]'::jsonb, false, 11),
('q12_location', '基本情報', 'お住まいの地域は？', '[
  {"value": "hokkaido", "label": "北海道"},
  {"value": "tokyo", "label": "東京都"},
  {"value": "kanagawa", "label": "神奈川県"},
  {"value": "osaka", "label": "大阪府"},
  {"value": "aichi", "label": "愛知県"},
  {"value": "fukuoka", "label": "福岡県"},
  {"value": "other", "label": "その他"}
]'::jsonb, false, 12);

INSERT INTO public.persona_section_definitions (id, title, description, generation_prompt, sort_order, editable, applicable_persona_types) VALUES
('core_identity', 'コアアイデンティティ', '基本的な人物像。年齢層、ライフスタイル、性格の概要', 'Generate the core identity section for this persona.', 1, true, ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery']),
('communication_rules', 'コミュニケーションルール', 'メッセージの特徴、会話の進め方、ユーモアの使い方', 'Generate the communication rules section.', 2, true, ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery']),
('personality_profile', 'パーソナリティプロファイル', '性格軸のスコアと解釈（内向↔外向、計画↔即興、論理↔感情）', 'Generate the personality profile section.', 3, true, ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery']),
('interests', '興味・関心マップ', '深い関心 / 普通の関心 / 浅い関心に分類した話題と具体的なエピソード', 'Generate the interests map section.', 4, true, ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery']),
('values', '価値観', '人生・仕事・人間関係における大切にしていること', 'Generate the values section.', 5, true, ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery']),
('romance_style', '恋愛スタイル', '理想の関係性、連絡頻度、NG条件', 'Generate the romance style section.', 6, true, ARRAY['wingfox']),
('conversation_references', '会話リファレンス', 'スピードデーティングの実際の発言サンプルと話し方の特徴分析', 'Extract conversation references from the provided dialogue.', 7, false, ARRAY['wingfox']),
('constraints', '制約事項', '不適切な内容の禁止、個人情報保護、AI表明義務', 'Use the system default constraints template.', 8, false, ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery']);
