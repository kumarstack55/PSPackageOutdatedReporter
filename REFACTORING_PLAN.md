# Refactoring Plan

`Invoke-ReportPackageOutdated.ps1` の見通しを改善するための段階的な分割計画です。

## 方針

- ユーザー向けの入口は `Invoke-ReportPackageOutdated.ps1` のまま維持する。
- `PSPackageOutdatedReporter.psm1` はテスト可能なモジュール境界として維持する。
- 各段階で既存の動作を変えず、Windows PowerShell 5.1 とPesterで検証する。
- プロバイダー固有処理と、キャッシュ・モデル・バージョン処理などの共通処理を分離する。
- 1関数1ファイルにはせず、責務単位でファイルをまとめる。

## Stage 0: 現状を固定する

Status: [x] 完了

- 現行テストが通ることを確認する。
- 公開されている関数と、`Invoke-ReportPackageOutdated.ps1` の実行時挙動を一覧化する。
- この計画を追加する。

完了条件:

- 変更前のテスト結果を記録できる。
- 後続の移動で確認すべき関数群が明確になっている。

## Stage 1: 共通コードを分割する

Status: [x] 完了

### Stage 1-1: モデル定義を分割する

Status: [x] 完了

- `PackageVersion`、`UpgradeTarget`、`SoftwarePackage` を `Private/Models.ps1` へ移動する。
- メインスクリプトとモジュールimportの両方で、モデルを共通処理より先に読み込む。
- 既存の表示メソッドと型定義を維持する。

検証:

- Windows PowerShell 5.1で既存のPesterテストが通ること。
- モジュールimport時にクラス型が解決されること。

### Stage 1-2: キャッシュ処理を分割する

Status: [x] 完了

- リリース日キャッシュの読み書き、キー生成、キャッシュエントリ変換を `Private/Cache.ps1` へ移動する。
- `Models.ps1` の後に読み込み、`PackageVersion` を変換処理から利用できるようにする。
- 既存のcache schema、cache key、公開関数名を維持する。

検証:

- Windows PowerShell 5.1で既存のPesterテストが通ること。
- キャッシュの保存と読み込みが従来どおり動作すること。

### Stage 1-3: バージョン処理を分割する

Status: [x] 完了

- PowerShell引数のエスケープ、バージョン正規化、バージョン比較を `Private/Version.ps1` へ移動する。
- upgrade command生成やレポート名生成など、provider・表示に属する処理はこの段階では移動しない。
- 既存の公開関数名とバージョン比較の挙動を維持する。

検証:

- Windows PowerShell 5.1で既存のPesterテストが通ること。
- 引数のクォートとバージョン比較が従来どおり動作すること。

### Stage 1-4: 表示処理を分割する

Status: [x] 完了

- 相対リリース日表示とステージ状態表示を `Private/Formatting.ps1` へ移動する。
- `Formatting.ps1` を `Models.ps1` より先に読み込み、モデルの表示メソッドから相対日付関数を利用できるようにする。
- 表示内容と公開関数名を維持する。

検証:

- Windows PowerShell 5.1で既存のPesterテストが通ること。
- 過去、未来、当日の相対日付表示が従来どおり動作すること。

### Stage 1-5: レポート処理を分割する

Status: [x] 完了

- レポート名生成と `Write-OutdatedPackageReport` を `Private/Report.ps1` へ移動する。
- `Report.ps1` はFormatting、Models、Versionに依存するため、それらの後に読み込む。
- 表の列名、WinGetの表示名、詳細レポートの出力内容を維持する。

検証:

- Windows PowerShell 5.1で既存のPesterテストが通ること。
- モジュールimport時にレポートが実行されないこと。

追加するファイル:

- `Private/Models.ps1`
- `Private/Cache.ps1`
- `Private/Version.ps1`
- `Private/Formatting.ps1`
- `Private/Report.ps1`

対象:

- `PackageVersion`、`UpgradeTarget`、`SoftwarePackage`
- リリース日キャッシュの読み書きとキー生成
- バージョン比較とPowerShell引数のエスケープ
- 相対日付表示とステージ表示
- `Write-OutdatedPackageReport`

検証:

- 既存のPesterテスト
- モジュールのimportでレポートが実行されないこと
- 直接スクリプトを実行したときの出力が変わらないこと

## Stage 2: WinGetを分割する

Status: [x] 完了

追加するファイル:

- `Private/Providers/WinGet.ps1`

対象:

- WinGet manifest URL生成
- WinGet release date解決
- WinGet upgrade command生成
- WinGet package問い合わせと結果変換

検証:

- manifest URL生成
- 非対応sourceでHTTPリクエストを実行しないこと
- WinGet CLI/moduleエラー時に空の結果を返すこと

## Stage 2a: レポート表示を整理する

Status: [x] 完了

Stage 1の完了を待たず、現在の `Write-OutdatedPackageReport` に対して先に実施する。表示仕様を先に固定してからStage 1の分割へ進むことで、構造変更と表示変更を同時に行わないようにする。

実装順:

1. Stage 2a-1で表の仕様と列名を確定する。
2. Stage 2a-2でWinGetの表示名を整理する。
3. Stage 2a-3で日付列を分離し、表示テストを追加する。

### Stage 2a-1: 表の仕様と列名を確定する

Status: [x] 完了

対象:

- `InstalledDate` を、インストールされたバージョンのリリース日だと明確にわかる列名へ変更する。
- `LatestDate` を、最新バージョンのリリース日だと明確にわかる列名へ変更する。
- 絶対日付と相対表示（`... ago`、`in ...`、`Unknown (...)`）を別列にする。

列名の第一候補:

- `InstalledVersionReleaseDate`
- `InstalledVersionReleaseRelative`
- `LatestVersionReleaseDate`
- `LatestVersionReleaseRelative`

`ReleasedAt` は日時値を想起させる一方、現在の表は日付と相対表示を扱うため、表の列名には `ReleaseDate` を使う。相対表示側は過去だけでなく未来や不明状態も含むため、`Age` が意味に合わない場合は `ReleaseDateRelative` へ変更する。

### Stage 2a-2: WinGetの表示名を整理する

Status: [x] 完了

対象:

- WinGetの表形式レポートでは、`Name` の末尾に付く ` (PackageId)` を表示しない。
  - 対象はWinGetに限定する。
  - 末尾の括弧部分を削除する処理は、既存のpackage ID表現を壊さないよう、末尾だけを対象にする。

検証:

- WinGetの表示名から末尾の ` (PackageId)` だけが除去される。
- 他のパッケージマネージャーの表示名は変わらない。
- パッケージ名自体に括弧が含まれる場合、末尾のpackage ID以外は削除されない。

### Stage 2a-3: 日付列を分離し、表示を検証する

Status: [x] 完了

対象:

- 表の絶対日付列と相対表示列を別々に出力する。
- Stage 2a-1で確定した列名を適用する。
- 日付表示に必要なヘルパーを、後の `Formatting.ps1` 分割で移動しやすい形にする。

検証:

- 表の列名からInstalled/Latestのどちらのバージョンに対応する日付か判別できること。
- 絶対日付列と相対表示列が別々に出力されること。
- 日付不明、過去、当日、未来の各状態で列の意味が崩れないこと。
- 既存の詳細表示（アップグレード対象行）は、必要な情報を失わないこと。

## Stage 3: Chocolateyを分割する

Status: [x] 完了

追加するファイル:

- `Private/Providers/Chocolatey.ps1`

対象:

- Chocolatey version history取得
- ODataのPublished date解析
- Chocolatey upgrade command生成
- outdated結果の解析と結果変換

検証:

- ChocolateyのPublished date解析
- package IDやversionのエスケープ
- `choco` 未インストール時の扱い
- CLIの不正行を無視すること

## Stage 4: Scoopを分割する

Status: [ ] 未着手

追加するファイル:

- `Private/Providers/Scoop.ps1`

対象:

- `scoop status` の結果解析
- `scoop info` からのbucket取得
- Scoop manifestのrelease date解決
- Scoop upgrade command生成
- Scoop package結果変換

検証:

- オブジェクト形式とテキスト形式のstatus解析
- bucket/source filter
- Git未インストール時の扱い
- release dateが取得できない場合のキャッシュ

## Stage 5: キャッシュ付きrelease date解決を共通化する

Status: [ ] 未着手

各プロバイダーに残った以下の重複を共通関数へ集約する。

```text
cache key生成
  -> TTL確認
  -> provider固有のrelease date取得
  -> cache entry保存
  -> PackageVersion生成
```

共通関数はprovider固有のHTTP、CLI、Git処理を知らず、release dateを取得する処理だけを受け取る形にする。

完了条件:

- WinGet、Chocolatey、Scoopのrelease date解決で同じキャッシュ処理を使う。
- provider固有コードの責務が、外部データの取得と解析に限定されている。
- 既存のcache schemaとcache keyを変更しない。

## Stage 6: 実行制御と読み込み順を整理する

Status: [ ] 未着手

- `PSPackageOutdatedReporter.psm1` から各ファイルを決められた順序でdot-sourceする。
- `Models.ps1` をproviderより先に読み込む。
- `Invoke-ReportPackageOutdated.ps1` はパラメーター受付と実行制御に集中させる。
- providerの選択処理が増えすぎた場合のみ、provider registryの導入を検討する。

完了条件:

- module importでレポートが実行されない。
- 既存のコマンドライン引数、出力、cache pathを維持する。
- Pesterテストを共通処理とprovider別に整理できる。

## 各Stageの完了手順

1. 小さな範囲を移動または変更する。
2. Windows PowerShell 5.1で `Invoke-Pester .\tests` を実行する。
3. 直接実行とmodule importの両方を確認する。
4. 完了したStageのStatusを `[x] 完了` に変更する。
5. 想定外の設計判断や未解決事項をこのファイルに追記する。

## 現時点の未解決事項

- PowerShell 5.1でのclass読み込み順をStage 1で実際に確認する。
- 既存の関数をmoduleから引き続きexportするか、内部関数を非公開にするかをStage 6で判断する。
- provider registryは、3プロバイダーの分割後も実行制御が複雑な場合にだけ導入する。

