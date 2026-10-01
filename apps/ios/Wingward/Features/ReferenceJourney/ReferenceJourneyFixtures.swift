#if DEBUG
import Foundation

enum ReferenceJourneyFixtures {
  static let stationOptions = [
    ReferenceLocationOption(id: "jp-tokyo-shimokitazawa", title: "下北沢駅", areaID: "jp-tokyo-setagaya"),
    ReferenceLocationOption(id: "jp-tokyo-shibuya", title: "渋谷駅", areaID: "jp-tokyo-shibuya")
  ]

  static let areaTitles = [
    "jp-tokyo-setagaya": "世田谷区",
    "jp-tokyo-shibuya": "渋谷区"
  ]

  static let profileDraft = ReferenceProfileDraft(
    name: "Yui",
    birthYear: "1998",
    gender: .woman,
    preferenceMode: .selected,
    preferredGenders: [.man, .nonbinary],
    locationMode: .station,
    stationID: "jp-tokyo-shimokitazawa",
    broadAreaID: "jp-tokyo-setagaya"
  )

  private static let aoi = ReferenceCandidate(
    id: "aoi",
    name: "Aoi",
    age: 27,
    imageName: "aoi-watercolor",
    match: 92,
    location: "中目黒・東京",
    summary: "静かな好奇心と、相手の話を広げる温かさを持つプロダクトデザイナー。",
    signature: "好奇心を会話に変える、穏やかな探索者",
    reasons: [
      ReferenceCandidateReason(
        id: "aoi-pace",
        label: "会話のテンポ",
        detail: "急がず、相手の言葉を受け取ってから話す"
      ),
      ReferenceCandidateReason(
        id: "aoi-safety",
        label: "安心のつくり方",
        detail: "共感を言葉にして、自然に話を広げる"
      ),
      ReferenceCandidateReason(
        id: "aoi-weekend",
        label: "休日の過ごし方",
        detail: "静かな場所と小さな発見を好む"
      )
    ]
  )

  private static let ren = ReferenceCandidate(
    id: "ren",
    name: "Ren",
    age: 29,
    imageName: "ren-watercolor",
    match: 87,
    location: "清澄白河・東京",
    summary: "音楽とコーヒーが日課。余白のある対話と率直さを大切にしています。",
    signature: "言葉を急がず、信頼を育てる聞き手",
    reasons: [
      ReferenceCandidateReason(
        id: "ren-distance",
        label: "距離の縮め方",
        detail: "小さなやり取りを重ねて信頼を育てる"
      ),
      ReferenceCandidateReason(
        id: "ren-words",
        label: "言葉の選び方",
        detail: "率直さと相手への配慮を両立する"
      ),
      ReferenceCandidateReason(
        id: "ren-rhythm",
        label: "日常のリズム",
        detail: "一人の時間も二人の時間も大切にする"
      )
    ]
  )

  private static let mio = ReferenceCandidate(
    id: "mio",
    name: "Mio",
    age: 26,
    imageName: "mio-watercolor",
    match: 82,
    location: "吉祥寺・東京",
    summary: "本と旅の話が好き。自然体のまま、新しい視点を分け合える関係が理想です。",
    signature: "日常から小さな冒険を見つける観察者",
    reasons: [
      ReferenceCandidateReason(
        id: "mio-curiosity",
        label: "好奇心",
        detail: "違いを楽しみ、新しい視点を分け合える"
      ),
      ReferenceCandidateReason(
        id: "mio-pace",
        label: "関係のペース",
        detail: "自然体のまま少しずつ知り合う"
      ),
      ReferenceCandidateReason(
        id: "mio-time",
        label: "大切にする時間",
        detail: "本や旅の体験を言葉にして共有する"
      )
    ]
  )

  static let data = ReferenceJourneyData(
    candidates: [aoi, ren, mio],
    wardSessions: [
      ReferenceWardSession(
        id: "ward-01",
        name: "Ward 01",
        caption: "こんにちは。まずは気楽に、あなたの言葉で話してください。"
      ),
      ReferenceWardSession(
        id: "ward-02",
        name: "Ward 02",
        caption: "うまくまとめなくて大丈夫です。思い浮かんだ順に聞かせてください。"
      ),
      ReferenceWardSession(
        id: "ward-03",
        name: "Ward 03",
        caption: "これが最後の会話です。普段どおりのテンポで話してみましょう。"
      )
    ],
    wardMessagesByCandidate: [
      "aoi": [
        ReferenceChatMessage(
          id: "w1",
          side: .theirs,
          actor: "AoiのWard",
          text: "Aoiは新しい場所を見つける時間が好きです。休日の過ごし方に近さを感じました。",
          time: "20:39"
        ),
        ReferenceChatMessage(
          id: "w2",
          side: .mine,
          actor: "あなたのWard",
          text: "こちらも小さな店や映画館を見つけるのが好きです。静かに話せる場所だと、より自然に過ごせそうです。",
          time: "20:40"
        ),
        ReferenceChatMessage(
          id: "w3",
          side: .theirs,
          actor: "AoiのWard",
          text: "会話のペースも近そうですね。最初は最近見つけた場所の話から始めると、お互いを知りやすそうです。",
          time: "20:41"
        )
      ]
    ],
    personMessagesByCandidate: [
      "aoi": [
        ReferenceChatMessage(
          id: "h1",
          side: .theirs,
          actor: "Aoi",
          text: "こんにちは。Ward同士の会話を読んで、映画館の話をしてみたくなりました。",
          time: "20:44"
        ),
        ReferenceChatMessage(
          id: "h2",
          side: .mine,
          actor: "あなた",
          text: "こんにちは！私もです。最近行ってよかった場所はありますか？",
          time: "20:45"
        )
      ]
    ],
    selfImageName: "yui-watercolor",
    insightTags: ["丁寧に聴く", "率直でやわらかい", "信頼を急がない"],
    insightSections: [
      ReferenceInsightSection(
        id: "conversation",
        title: "会話の入り方",
        body: "共通の出来事や身近な話題から始めると、緊張がほどけて本来の聞き上手な面が表れます。質問を重ねすぎず、自分の小さな体験も添える会話が似合います。"
      ),
      ReferenceInsightSection(
        id: "trust",
        title: "信頼の築き方",
        body: "以前の会話を覚えて次につなげることや、相手の背景を決めつけずに聞くことを大切にします。短時間の盛り上がりより、安心して戻れる関係を選ぶ傾向があります。"
      ),
      ReferenceInsightSection(
        id: "values",
        title: "大切にしていること",
        body: "一人で整える時間と、誰かと気持ちを共有する時間の両方が必要です。意見が違うときも理由を聞き合い、二人で納得できる進み方を探したいと考えています。"
      )
    ]
  )
}
#endif
