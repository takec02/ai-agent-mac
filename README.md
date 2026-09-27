# AIエージェント

Mac に常駐する、ローカル音声対話 AI アシスタント。自分で名前をつけたエージェントに呼びかけるだけで、会話や Mac の操作、Web 検索、カメラで見たものの説明、同時通訳までできます。

このリポジトリには2つの版があります。

| | Mac アプリ版「AIエージェント」（おすすめ） | Python 版 |
|---|---|---|
| 場所 | [`mac/`](mac/) | このページの以下 |
| 形 | メニューバー常駐 or ウィンドウのネイティブアプリ | ターミナルで動くスクリプト |
| 名前 | **初回起動時に自分で名前をつける**（必須） | 設定ファイルで指定（既定: サスケ） |
| 呼びかけ | 「名前＋応えて」（既定）。形と言葉は設定で変更可。それ以外の会話には反応しない | 名前（＋設定した別表記） |
| 音声認識 | macOS 内蔵（追加ダウンロードほぼ不要） | Whisper（1.6GB） |
| 動作環境 | macOS 26 以降 | macOS 14 以降 |

## Mac アプリ版「AIエージェント」

中央の幾何学的なコアが、待機・聞き取り・思考・発話に合わせて回転・脈動します。会話は新しいものほど上に現れ、古い発言は下へ押し出されながら、あなたの発言は左へ、AI の発言は右へ流れて消えていきます。

### 使い始めるのに必要なこと

**必須**

| やること | 方法 |
|---|---|
| Mac の条件 | Apple Silicon（M1 以降）、**macOS 26 以降**、ビルドに Xcode（Swift 6） |
| ローカル AI を用意 | [Ollama](https://ollama.com/download) をインストールして起動し、`ollama pull qwen3-vl:8b-instruct`（約 6GB。文章・ツール・写真のすべてに対応） |
| アプリをビルド | 下のコマンドで `/Applications` にインストール |
| 初回設定 | 起動すると表示される画面で、性別・名前・呼ばれ方を決めて「起動する」 |
| 呼びかけ方 | 「サスケ、応えて。今何時？」のように、名前のあとに呼びかけの言葉を付けます（設定 → 一般 で「名前だけ」「ヘイ＋名前」にも変更可） |
| マイクの許可 | 初回に出るダイアログで許可（出ないときは「システム設定 → プライバシーとセキュリティ → マイク」） |
| 音声認識モデル | 初回起動時に macOS が自動でダウンロード（数分かかることがあります） |

```bash
cd mac
./build.sh --install   # ビルドして /Applications にインストール・起動（ビルドは ~/Library/Caches/AIAgent/build に作られます）
```

**必要に応じて**（すべて「設定」画面から登録。API キーは Mac のキーチェーンに保存されます）

| 使いたい機能 | 必要なもの |
|---|---|
| Web 検索（ローカル・GPT・Gemini 使用時） | [Tavily](https://app.tavily.com) の API キー（月1,000回まで無料、クレジットカード不要）→ 設定 → AI |
| Claude を使う | [Anthropic Console](https://console.anthropic.com/settings/keys) の API キー（従量課金）→ 設定 → AI。Web 検索も使うなら、Console の設定で Web 検索を有効にする |
| GPT を使う | [OpenAI](https://platform.openai.com/api-keys) の API キー（従量課金）→ 設定 → AI |
| Gemini を使う | [Google AI Studio](https://aistudio.google.com/apikey) の API キー（無料枠あり）→ 設定 → AI |
| 自然な声にする | 「システム設定 → アクセシビリティ → 読み上げコンテンツ → システムの声 → 声を管理」から、男性なら **Otoya**、女性なら **Kyoko** の「拡張」または「プレミアム」を追加（自動で使われます） |
| 音楽の操作 | 初回に「ミュージックを操作する許可」のダイアログが出たら許可 |
| 他のアプリとの連携（MCP） | 連携先の MCP サーバーを設定 → 連携 から追加（下記「MCP サーバーの追加」） |
| Google（Gmail・カレンダー・Drive など） | Google Cloud でクライアントを作り、設定 → 連携 →「Google を追加」で登録（[準備の手順](docs/google-setup.md)） |
| 会議の記録・字幕 | 初回に「システムオーディオの録音」の許可ダイアログが出たら許可 |
| カメラ（見せたものを説明・文字や QR の読み取り） | 初回に出るカメラの許可ダイアログで許可 |
| お知らせ（自分から知らせる） | 通知の許可（初回に出るダイアログ、または「システム設定 → 通知 → AIエージェント」） |
| 同時通訳・字幕 | 設定 → 通訳 で相手の言語を選び、「翻訳データを入れる」を押す（端末内で翻訳。押さない間は AI が訳します） |
| 業務サービス | 設定 → 連携 から追加（下記「連携できるサービス」）。多くは Node.js（`npx`）が必要 |

> Claude Pro / ChatGPT Plus などの月額プランでは API は使えません。API は別契約の従量課金です。

### 機能

- 初回起動時に、まずエージェントの性別（男性・女性で声と話し方が変わる）を選び、名前（必須）と呼びかけの言葉（任意、空欄なら名前＋「応えて」）を決めます。名前の初期値は男性なら「サスケ」（猿飛佐助）、女性なら「トモエ」（巴御前）で、自由に変更できます。あなたの呼ばれ方＋敬称（初期値「あなた」、敬称なし）もここで決めます
- 音声認識が名前を漢字で書き起こしても（「さすけ」→「佐助」）、読みで照合するので反応します
- 表示方法は「ウィンドウ＋Dock」（既定）と「メニューバーのみ」から選べます（設定でいつでも変更可）
- 呼びかけたあとは、しばらく（既定3分。設定で変更可）名前を呼ばずに話し続けられます。残り時間は画面に出ます
- AI はローカル (Ollama) / Claude / GPT / Gemini を設定画面か音声で切り替え。API キーはキーチェーンに保存
- **MCP（Model Context Protocol）対応**: MCP サーバーのツールを、どの AI からでも使えます（下記）
- **Web 検索**:「〇〇を調べて」でインターネットを検索し、ページも読んで答えます。ローカル・GPT・Gemini では [Tavily](https://tavily.com)（月1,000回まで無料、設定 → AI で API キーを登録）、Claude では Claude 内蔵の Web 検索（Anthropic Console で Web 検索を有効にしておく必要あり）を使います
- **カメラ**:「これ何？」「これ読んで」「QR コード読んで」で1枚撮って答えます。写っている文字と QR・バーコードは Mac の中で読み取り、物の見た目は画像を読めるモデル（既定の qwen3-vl や Claude など）が説明します。撮った写真は画面に出るので、何を見たのかを確かめられます。画面下のボタンやドラッグ＆ドロップで、手元の画像を見せることもできます
- **同時通訳**: 地球のボタン（または「通訳して」）で、日本語と相手の言語を同時に聞き取り、もう一方の言語で読み上げます。相手の言語は設定で選べます（英語・スペイン語・中国語・韓国語など）
- **字幕**: 吹き出しのボタン（または「字幕出して」）で、会議や動画など Mac で鳴っている音声を日本語字幕にして画面の前面に出します（クリックはすり抜けます）
- **資料について答える（NotebookLM のような使い方）**: 画面の本のボタンから PDF・Word・PowerPoint・Excel・テキスト・画像を登録すると、その内容について質問できます。「有給の繰り越しは？」と聞くと、関係する箇所を探して、どの資料の何ページに書かれていたかを添えて答えます。資料は Mac の中だけに置かれ、質問に関係する箇所だけが AI に渡ります（画像だけの PDF は文字認識にかけます）
- **会話の記録**: これまでの会話は日ごとに保存され、時計のボタンから読み返せます。言葉で検索もできます（`書類 > AIエージェント > 会話ログ`）
- **長期記憶とパーソナル指示**:「〇〇と覚えておいて」で覚え、次回以降の判断に使います。設定 → 記憶 で一覧・編集・削除ができ、記憶ごとに「ローカル AI のときだけ使う」を選べます。自由記述の指示（「結論から先に」など）も設定できます
- **お知らせ（自分から知らせる）**: 設定 → お知らせ で「毎日8時」「30分ごと」「毎月25日」などの決まりを作ると、その時刻に自分で調べ、知らせることがあるときだけ声と通知で伝えます。何もなければ黙ります。静かな時間（既定 22時〜7時）は通知だけにします
- **会議の記録と要約**:「会議を記録して」（または画面の ● ボタン）で、Meet・Zoom・Teams など Mac で鳴っている相手の声と、マイクの自分の声を分けて文字起こしします。「会議を終了して」で、選んでいる AI が要約・決定事項・宿題をまとめて読み上げ、議事録を `書類/AIエージェント/議事録/` に保存します（議事録は会議中から少しずつ書き込むので、途中でアプリが落ちても残ります）。ヘッドホンを使うと、相手の声がマイクに入らず「自分」「相手」の区別が正確になります
- **Google 連携**: Gmail・カレンダーに加えて、ドライブのフォルダを作る・探す、スプレッドシートを読むといったことを会話から頼めます（「勤務表フォルダの中に10月のフォルダを作って」「このフォルダの中身を名簿と突き合わせて」など）。会社の Google Workspace は Google 公式の MCP サーバー、個人の Gmail は有志の MCP サーバーでつなぎます。ブラウザでのログインに対応し、ログイン情報はキーチェーンに保存・自動更新します（[準備の手順](docs/google-setup.md)）
- **予定の重なり確認**: カレンダーに予定を入れるとき、同じ時間帯に予定があれば「〇〇が入っていますが、よろしいですか？」と確認します。どのカレンダーを見るかは設定 → 予定・提出物 で選べます（仕事用など別アカウントも対象にできます）
- **計算**: 割引・税込み・割り勘・単位換算などは、AI に暗算させず、アプリの中の計算機で計算します（決められた計算だけを行い、それ以外は受け付けません）
- **天気**: 気象庁のデータで今日・明日の天気・降水確率・予想気温を答えます（市区町村名でも可）。「ウェザーニュースで見せて」でウェザーニュースのページをブラウザで開きます（同サイトは規約で自動取得が禁止されているため、中身は読みに行きません）
- 呼びかけの言葉を付ける形（既定）だと、周りの会話やテレビへの誤反応が減ります。名前だけで反応させることもできますが、その場合は日常会話に出てこない名前にするのがおすすめです

### 連携できるサービス

設定 → 連携 の各フォームから追加できます。いずれも各社公式の MCP サーバーです。API キーやパスワードは Mac のキーチェーンに保存され、設定ファイルには書かれません。**書き込み（送信・作成・更新・削除など）は、実行前に声か画面で確認します。**

| サービス | つなぎ方 | 必要なもの |
|---|---|---|
| Google（Gmail・カレンダー・Drive・ドキュメント・スプレッドシート・スライド） | ブラウザでログイン | Google Cloud のクライアント（[準備の手順](docs/google-setup.md)） |
| Notion | ブラウザでログイン（アプリ登録は自動） | Notion のアカウント |
| freee | ブラウザでログイン（アプリ登録は自動） | freee のアカウント（使える機能は契約プランと権限による） |
| Slack | ブラウザでログイン | Slack で作った社内アプリのクライアント ID・シークレット（管理者の承認が必要） |
| HubSpot | ブラウザでログイン | HubSpot の MCP auth app のクライアント ID・シークレット |
| Salesforce | ブラウザでログイン | Enterprise Edition 以上か Developer Edition。管理者が MCP サーバーと外部クライアントアプリを設定 |
| GitHub | トークン | 個人用アクセストークン |
| Zapier | トークン | Zapier の MCP 接続トークン（公式 MCP がないサービスも Zapier 経由でつなげる） |
| Backlog | API キー | スペースのドメインと API キー |
| kintone | API トークン | kintone の URL と API トークン（またはログイン名・パスワード） |
| Figma | Mac の中のアプリにつなぐ | Figma デスクトップ版で Dev Mode MCP Server をオン（有料プランの Dev / Full 席） |

ログインが必要なサービスで、自分で作ったアプリのクライアントを使う場合、リダイレクト URL には `http://127.0.0.1:8723/oauth2callback` を登録します。MCP 標準のログイン（自動検出と自動登録）に対応したサーバーなら、「その他（URL を指定）」から URL だけで追加できます。

### MCP サーバーの追加

設定の「連携」タブ →「設定ファイルを開く」で `~/Library/Application Support/AIAgent/mcp.json` を編集し、「再読み込み」を押します。書式は Claude Desktop などと同じ `mcpServers` 形式です。

```json
{
  "mcpServers": {
    "files": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"] },
    "remote": { "url": "http://127.0.0.1:8080/mcp", "headers": { "Authorization": "Bearer ..." } },
    "myapp": { "discovery": "~/Library/Application Support/MyApp/mcp.json" },
    "private": { "command": "...", "localOnly": true }
  }
}
```

- `command`: コマンドを起動して標準入出力（stdio）で接続
- `url`: Streamable HTTP で接続（`headers` で認証ヘッダーを付けられる）
- `discovery`: 起動中のアプリが書き出す接続情報ファイル（`{"url": ..., "token": ...}`）を読んで接続。アプリの起動ごとにポートやトークンが変わる場合向け
- `"disabled": true` で一時的に無効化。未接続のサーバーには1分ごとにつなぎ直します
- `"localOnly": true` にしたサーバーのツールは、**AI がローカル（Ollama）のときだけ**使えます。Claude / GPT / Gemini を選んでいる間は AI に見せず、呼び出されても実行しません。また、そのツールを使ったやりとりは、あとからクラウドの AI に切り替えても会話履歴として送りません。メールなど、Mac の外に出したくないデータを扱うサーバーに使ってください
- ツールの結果に含まれる指示には従わないよう AI に指示しています。送信・削除など取り消せない操作をするツールを持つサーバーを追加するときは注意してください

---

以下は Python 版の説明です。

- **完全ローカルで動作**（音声認識・AI・音声合成すべて Mac 内。無料・オフライン可）
- **AI を切り替え可能**：ローカル (Ollama) / Claude / GPT / Gemini、ほか OpenAI 互換 API。会話中に「クロードに切り替えて」と話すだけで切り替わる
- **Mac を操作**：時刻・天気・バッテリー、アプリ起動、音量、音楽、Web 検索（ブラウザで開く）、ショートカット.app の実行
- **文ごとに順次読み上げ**るので返事が速い

```
 マイク ─▶ 発話区間検出 ─▶ 音声認識 ─▶ 名前の検出 ─▶ AI (＋ツール) ─▶ 音声合成 ─▶ スピーカー
          WebRTC VAD      mlx-whisper                 Ollama / Claude     macOS say
                          large-v3-turbo              / GPT / Gemini
```

## 動作環境

- Apple Silicon の Mac（M1 以降。メモリ 16GB 推奨）
- macOS 14 以降
- 空き容量 約 9GB（ローカル AI モデル 6GB ＋ 音声認識モデル 1.6GB ＋ Python 環境）

## セットアップ

```bash
git clone https://github.com/takec02/ai-agent-mac.git
cd ai-agent-mac
./scripts/setup.sh
```

`setup.sh` は [uv](https://github.com/astral-sh/uv) と [Ollama](https://ollama.com) を Homebrew で入れ、Python 環境を作り、ローカル AI モデル `qwen3-vl:8b-instruct` をダウンロードします。Ollama アプリ（またはサービス: `brew services start ollama`）が起動している必要があります。

## 使い方

```bash
./scripts/run.sh                  # 音声モードで起動
./scripts/run.sh --text           # キーボードで会話（マイクなしで動作確認したいとき）
./scripts/run.sh --backend claude # 起動時の AI を指定
```

初回起動時は音声認識モデル（約 1.6GB）をダウンロードするので数分かかります。マイクの使用許可を求められたら許可してください。

設定した名前（既定は「サスケ」）で呼びかけると「チン」と鳴ります。「サスケ、今何時？」のように続けて言っても、呼んでから話しても大丈夫です。

| 話しかける例 | 動作 |
|---|---|
| 今何時？ / 東京の天気は？ / バッテリーどれくらい？ | 情報を答える |
| Safari 開いて / 音量を 30 にして / 音楽かけて / 次の曲 | Mac を操作 |
| 〇〇について検索して | ブラウザで検索 |
| 「朝のルーティン」を実行して | ショートカット.app を実行 |
| クロードに切り替えて / ジェミニにして / ローカルに戻して | AI を切り替え |
| 会話をリセットして | 会話の記憶を消去 |
| ありがとう / おやすみ | 待機状態に戻る |

音声認識が名前を漢字やひらがなで書き起こす場合（例:「佐助」）は、`config.toml` の `[wake] keywords` に追加してください。

## AI の切り替えと料金

| 名前 | 中身 | 料金 | 必要なもの |
|---|---|---|---|
| `local` | Ollama（既定: qwen3-vl:8b-instruct） | **無料** | なし |
| `gemini` | Google Gemini | **無料枠あり** | [Google AI Studio](https://aistudio.google.com/apikey) の API キー |
| `claude` | Anthropic Claude（既定: Claude Opus 5） | 従量課金 | [Anthropic Console](https://console.anthropic.com/) の API キー |
| `gpt` | OpenAI GPT | 従量課金 | [OpenAI Platform](https://platform.openai.com/api-keys) の API キー |

API キーは `.env` に書きます（`.env.example` 参照）。

> **注意**: Claude Pro / ChatGPT Plus などの月額サブスクリプションでは API は使えません。API は別契約の従量課金です。ただし音声アシスタントの会話は短いので、日常使いなら月数百円程度に収まることが多いです。Claude を安く速く使いたい場合は `config.toml` で `model = "claude-haiku-4-5"` に変更できます。

[Groq](https://console.groq.com/) や [OpenRouter](https://openrouter.ai/) など OpenAI 互換の API なら、`config.toml` に `[backends.名前]` を追加するだけで使えます（`config.example.toml` 参照）。

## 常駐起動（ログイン時に自動起動）

```bash
./scripts/install_launchd.sh            # 登録（落ちても自動で再起動）
tail -f ~/Library/Logs/voice-agent.log  # ログを見る
./scripts/install_launchd.sh uninstall  # 解除
```

launchd から起動したプロセスにはマイクの許可ダイアログが出ないことがあります。ログに認識結果が一切出ず反応しない場合は、先に一度ターミナルから `./scripts/run.sh` を実行してマイクを許可するか、「システム設定 > プライバシーとセキュリティ > マイク」を確認してください。

## カスタマイズ

設定はすべて `config.toml`（`config.example.toml` をコピーしたもの）にあります。

- **声**: `[tts] voice`。「システム設定 > アクセシビリティ > 読み上げコンテンツ > システムの声」から **Kyoko（拡張）** などの高品質な声を追加すると、より自然になります
- **呼ばれ方**: `[assistant] user_title = "殿"` のように指定します（既定は「あなた」）
- **ローカル AI のモデル**: `[backends.local] model`。`qwen3-vl:4b`（軽い）や `qwen3:8b` など、Ollama で入れたものを指定
- **ツールの追加**: `voice_agent/tools.py` に関数を書き、`TOOLS` と `_FUNCS` に登録するだけで、全ての AI から使えるようになります。コードを書かなくても、ショートカット.app で作ったショートカットは「〇〇を実行して」で呼べます

## うまく動かないとき

- **反応しない**: 認識結果のログを見て、名前がどう書き起こされているかを確認し、`[wake] keywords` に追加する
- **誤反応が多い**: 日常会話に出てこない名前に変える
- **話し終わる前に切られる**: `[audio] silence_seconds` を 1.2 などに増やす
- **ローカル AI が操作せず「しました」とだけ言う**: 小さいローカルモデルはツールの呼び出しを忘れることがあります。`[backends.local] think = true` にすると正確になりますが、返事がかなり遅くなります。Claude / GPT / Gemini なら確実です
- **ローカル AI の最初の返事が遅い**: モデルの読み込みに 20 秒ほどかかります。以後 30 分はメモリに保持されます（`keep_alive`）

## 使用しているオープンソース

**Mac アプリ版**（音声認識・音声合成は macOS 標準の機能を使用）

| ライブラリ | 用途 | ライセンス |
|---|---|---|
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | MCP クライアント | Apache-2.0（一部 MIT） |
| [swift-nio](https://github.com/apple/swift-nio) / [swift-log](https://github.com/apple/swift-log) / [swift-system](https://github.com/apple/swift-system) / [swift-collections](https://github.com/apple/swift-collections) / [swift-atomics](https://github.com/apple/swift-atomics) | MCP SDK の依存 | Apache-2.0 |
| [EventSource](https://github.com/mattt/eventsource) | MCP SDK の依存（SSE） | MIT |
| [workspace-mcp](https://github.com/taylorwilsdon/google_workspace_mcp) | 個人の Google アカウント用 MCP サーバー（任意、利用時に uvx で取得） | MIT |

**Python 版**

| ライブラリ | 用途 | ライセンス |
|---|---|---|
| [mlx-whisper](https://github.com/ml-explore/mlx-examples) / [Whisper](https://github.com/openai/whisper) | 音声認識 | MIT |
| [py-webrtcvad](https://github.com/wiseman/py-webrtcvad) | 発話区間検出 | MIT |
| [sounddevice](https://github.com/spatialaudio/python-sounddevice) | マイク入力 | MIT |
| [Ollama](https://github.com/ollama/ollama) | ローカル LLM 実行 | MIT |
| [Qwen3](https://github.com/QwenLM/Qwen3) | ローカル LLM | Apache-2.0 |

**利用している外部データ・サービス**

| サービス | 用途 | 条件 |
|---|---|---|
| [気象庁](https://www.jma.go.jp/) | 天気予報 | [政府標準利用規約](https://www.jma.go.jp/jma/kishou/info/coment.html)に基づき出典を明記して利用 |
| [Tavily](https://tavily.com) | Web 検索 | 利用者自身の API キーで利用 |

## 作者

[takec02.com](https://takec02.com/) — 作者のサイト。ほかに公開しているアプリもこちらにあります。

## ライセンス

MIT（このリポジトリのコード）。
