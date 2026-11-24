# DockBridge CI

このドキュメントでは `.github/workflows/ci.yml` の CI 設計方針を説明します。特に macOS テストの時間予算とタイムアウトの関係は、ウォッチドック導入以後に複数の調整を経ているため、ここに現在の根拠を固定しておきます。

## macOS テストの時間予算

### 実行構造

`Test macOS app` ステップは、以下の構成でテストを実行します。

1. perl の `alarm` によるウォッチドック（420 秒）が xcodebuild を包む
2. テスト単位のタイムアウト（`-default-test-execution-time-allowance`）で個別テストの暴走を防ぐ
3. exit 142（SIGALRM = ウォッチドック発火）の場合のみ、テスト全体がハングしたとみなし **1 回だけリトライ**する
4. テスト失敗（`.xcresult` の失敗数、またはログの `TEST EXECUTE FAILED` / `failed on '`）はリトライせず即失敗にする

### パラメータ一覧

| パラメータ | 値 | 役割 |
|---|---|---|
| ジョブ `timeout-minutes` | 45 | macOS ジョブ全体の上限（過去に xcodebuild が 6 時間停止した実績への対処） |
| `Build and test macOS app` ステップ `timeout-minutes` | 33 | 共有 composite action（`.github/actions/run-macos-tests`）全体の上限（ビルド 15 分 + テスト 18 分） |
| ビルドウォッチドック `alarm` | 900 秒 | `xcodebuild build-for-testing` のハングを 15 分で打ち切り |
| テストウォッチドック `alarm` | 420 秒 | テスト全体の無反応（testmanagerd スタール）を検知して kill |
| `-default-test-execution-time-allowance` | 300 秒 | 1 テストあたりの実行上限。超過は個別テストの失敗となる |
| リトライ回数 | 1（MAX_ATTEMPTS=2） | ランナー側スタールは flaky なので 1 回だけ再試行 |
| リトライ間の `sleep` | 5 秒 | kill 後のクリーンアップ待ち |

### 最悪所要時間の見積もり

2 回ともウォッチドック発火（420 秒ずつ）で kill される最悪ケースは次式です。

```text
初回 420 秒 + リトライ待機 5 秒 + 2 回目 420 秒 = 845 秒 ≒ 14.1 分
```

ビルド上限（900 秒 = 15 分）とテスト最悪ケース（845 秒 ≒ 14.1 分）の合計は約 29.1 分で、呼び出し側ステップの `timeout-minutes: 33` に収まります（xcodebuild 起動や結果検証のオーバーヘッドを含めても約 4 分の余裕）。ジョブタイムアウト 45 分にも収まります。また失敗時の診断・artifact アップロード（`.github/actions/upload-macos-test-diagnostics`）は `if: failure()` の独立した外側ステップとして実行されるため、ステップタイムアウトや結果件数検証の失敗時でもログと `.xcresult` を回収できます（#266）。

`timeout-minutes: 33` がビルド上限（900 秒）とテスト最悪ケース（845 秒）の合計を覆っていることは理論計算で確認しています。最悪ケース自体が実際に観測されたことはまだありません（正常時は約 2 分、ビルド込みで約 13 分）。将来 2 回連続でウォッチドックが発火した実行が観測された場合は、この計算値と実際の所要時間を突き合わせてください。

テスト成功後は `scripts/verify-macos-test-results.py` が `.xcresult` のサマリーとテストツリーを突き合わせ、`failedTests == 0`、最低合格件数（`DEFAULT_MIN_PASSED_TESTS`）、および `ALLOWED_SKIPPED_TESTS` 外の `XCTSkip` が 0 件であることを検証します（#1435）。許可リスト外のスキップが 1 件でも発生した場合、CI は失敗します。

### タイムアウトの棲み分け

| 状況 | 検知 | 結果 |
|---|---|---|
| 個別テストが遅く 300 秒超過 | `failed on ... (300.000 seconds)` | 実テスト失敗として即失敗（リトライしない） |
| テストが assert 失敗 | `.xcresult` の `failedTests` / `TEST EXECUTE FAILED` / `failed on '` | 実テスト失敗として即失敗（リトライしない） |
| テスト全体が無反応（testmanagerd スタール等） | ウォッチドック 420 秒 → exit 142 | ハングとみなし 1 回リトライ |
| xcodebuild 自体がクラッシュ / 引数エラー | exit 142 以外の異常終了 | 決定的失敗として即失敗（リトライしない） |

テスト単位のタイムアウト（300 秒）とウォッチドック（420 秒）の起算点は異なります。順序保証が成立するのは、テストがラン開始から 120 秒以内に開始した場合です。120 秒を超えて開始したテストでは、300 秒の許容時間が切れる前に 420 秒のウォッチドックが先に発火し、そのテストは実テスト失敗ではなく環境ハングとしてリトライ対象になります。この境界条件を前提に、実装バグ由来の失敗と環境由来のハングを区別してください。

### テスト実行時間の実測

| 状況 | 実測 |
|---|---|
| 正常時（ユニットテストのみ） | 約 2 分未満 |
| ビルド込みの macOS ジョブ全体 | 約 13 分 |

Docker / SSH を使用する E2E テスト（`ManualTestPlanVerificationTests` など）は、CI ランナーに Docker がないため `XCTSkip` によりスキップされます。CI で実際に実行されるのはユニットテストのみです。

## リトライ判定

ウォッチドック（exit 142）による kill だけがリトライ対象です。実テスト失敗はリトライせず即失敗にします。判定の信頼順は次のとおりです。

1. `.xcresult` の `failedTests`（ディスク書き込み、stdio バッファに非依存）
2. ログ grep（`TEST EXECUTE FAILED` / `failed on '`）。ウォッチドックが `.xcresult` の書き込み途中で kill した場合のフォールバック

これは、ランナー側スタール（actions/runner-images#13096 系統）が flaky で再実行により成功しやすい一方、実装バグ由来の失敗をリトライ成功で隠蔽してはならない、という方針に基づきます。

## リトライ時のクリーンアップ

リトライ前に、自ステップのプロセスグループに属する xcodebuild だけを `pkill -g` で終了します。`TEST_HOST`（`DockBridge`）は testmanagerd がプロセスグループの外で起動するため、ステップ開始前の PID をスナップショットし、それ以外のホストだけを `kill` します。他ジョブの既存プロセスは巻き込みません（#267）。

## 失敗時の解析資料

テストステップが失敗・ハングした場合、各 attempt のログと `.xcresult` を artifact として保存します（#266）。`tee` によりコンソールにもリアルタイム出力されます。初回とリトライは attempt 番号で区別できます。

- ログ: `/tmp/xcodebuild-test-attempt-{N}.log`
- 結果バンドル: `/tmp/xcodebuild-test-attempt-{N}.xcresult`

失敗時は `xcresulttool` で `.xcresult` 内の失敗テスト一覧もコンソールに出します。

## E2E runner の誤合格回帰（#839 / F49）

[調査対象の main（31f5b562）](https://github.com/T3pp31/DockBridge/blob/31f5b56271f97919d5695b2233a80998e905a17e/scripts/e2e-verify.sh) には、`check` 内の `if "$@"` が Bash の `errexit` を無効にし、途中の失敗を最後の成功で隠す経路が残っていました。check 関数とその準備 helper は、必須コマンドの失敗を明示的に return する必要があります。

| 監査対象 | 回帰テストで観測する保証 |
|---|---|
| C001 / C002: host key reject / accept | reject は終了コード3とtrust未保存の両方が必須。accept は有効なtrustファイルが残ってもCLI失敗ならFAIL |
| C006 / C007: mkdir・rename・delete / recursive transfer | 各CLI操作と両方の比較が必須。途中失敗後に同じcheckの後続操作を行わず、summaryを失敗・終了コードを非0にする |
| C013: corrupted known_hosts | エラー文の検査前に、正常なtrust作成が成功していることが必須 |
| 同じ原因の周辺経路 | private-key authのtrust作成、downloadのCLI成功、設定・鍵生成helperの失敗伝播 |

`python3 scripts/test-e2e-verify.py -v` は、外部CLI・比較結果等を制御するfixtureと本物の `main` / `check` を使います。既存CIの `Test E2E log cleanup` ステップで実行されます。修正前には11の失敗注入ケースで誤った成功を検出し、修正後は既存のログ保持・cleanupを含む13テストが成功しました。`bash -n scripts/e2e-verify.sh` と `shellcheck -x scripts/*.sh` も成功しています。

この検証はrunnerの判定契約に限ります。実Docker/SFTP、Swift/Xcode、Rustの転送動作はここでは未実行です。#839 の全監査台帳は [docs/test-audit-2026-10-23.md](test-audit-2026-10-23.md) および [docs/test-ledger-2026-10-23.md](test-ledger-2026-10-23.md) を参照してください。

## テストスイート別の実行境界と保証（#839 / F57）

| スイート / コマンド | CI で自動実行されるか | 保証する内容 | CI 外・機能ゲート付き境界 |
|---|---|---|---|
| `cargo test --workspace --all-targets` | はい（Linux `rust`・macOS `macos`） | `dockbridge-core` / `dockbridge-cli` / `dockbridge-uniffi` の単体・結合テスト（インプロセス SFTP サーバ含む） | `#[ignore]` 付き実 OpenSSH `sftp-server` 検証・ベンチマーク・`root` 専用テストは別途実行 |
| `cargo test -p bssh-russh-sftp --lib` | はい（Linux `rust`） | ベンダー済み `bssh-russh-sftp` フォークの SFTP サーバ回帰テスト（プロトコル/転送/エラー変換） | なし |
| `cargo test -p dockbridge-cli --features disable-cli-password` | はい（Linux `rust`） | ハードニング済み CLI 構成（`--password-stdin` 等、平文 `--password` 禁止）のテスト | なし |
| `xcodebuild ... test-without-building` + `Verify macOS test result counts` | はい（macOS `macos`・unsigned） | Swift ユニットテスト・ViewModel/Bridge/ファイルドロップ結合テスト、および `.xcresult` の `totalTestCount >= 1` / `passedTests >= 1` / `failedTests == 0` 保証 | Docker SFTP E2E（`ManualTestPlanVerificationTests`）・署名済みアプリ Keychain / App Sandbox / 更新インストール検証は `XCTSkip` により明示的に分離 |
| `scripts/test-*.py`・`scripts/test-website-download.cjs`・`shellcheck -x scripts/*.sh` | はい（Linux `rust` / `website`、一部 macOS） | 検証スクリプト群の判定契約・失敗伝播・xcresult 集計・設定リーダ・ローカライズ整合性 | 実 Docker コンテナ・実 Accessibility/UI・実 `pfctl` によるオフライン検証は手動スクリプト実行時のみ |

## 関連する GitHub Issue

- #264: リトライ判定の盲点（`.xcresult` の失敗数を一次情報源にして対処）
- #265: テストタイムアウト 120 秒による環境要因の強制失敗（300 秒へ引き上げ）
- #266: 失敗・ハング時のログ / .xcresult 保存
- #267: リトライ時の pkill による他ジョブ誤 kill（プロセスグループと TEST_HOST の差分 PID で対処）
- #268: 本ドキュメント（時間予算の明文化）
