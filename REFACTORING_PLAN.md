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

Status: [ ] 未着手

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

Status: [ ] 未着手

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

## Stage 3: Chocolateyを分割する

Status: [ ] 未着手

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
