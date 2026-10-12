# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

Windows の仮想デスクトップごとにアプリ群を一括起動する個人用ランチャー。起動構成は「プリセット」として JSON で保存する。ビルド・lint・テストは存在しない。コードは [src/](src/) にまとめてある。

## 実行

```bat
src\quickStart.bat
```

または直接:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\launchApps.ps1
```

引数はなく、起動後の対話メニューでプリセットを選ぶ。プリセットを起動すると実際にアプリが立ち上がり、仮想デスクトップが新規作成される（既存のデスクトップは消さないため、再実行のたびに増える）ので、動作確認目的で勝手に起動まで進めない。

起動を伴わない確認方法:

```powershell
# 構文チェック
powershell -NoProfile -Command '$e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path src\launchApps.ps1),[ref]$null,[ref]$e); $e'
```

```bash
# メニューだけ動かす（標準入力で応答を渡す。起動確認には n を返す）
printf '1\r\nn\r\nq\r\n' | powershell -NoProfile -ExecutionPolicy Bypass -File src/launchApps.ps1
```

## 仕組み

- プリセットは `src/presets/<名前>.json`（スクリプトと同じフォルダの `presets/`）。個人環境の絶対パスを含むため `.gitignore` で Git の対象外にしており、フォルダがなければ新規作成時にスクリプトが作る。ファイル名がそのままプリセット名で、JSON 内に名前は持たない。`desktops` の外側の配列の順番が仮想デスクトップ 1, 2, ... に対応する。起動対象は文字列（パスまたは URL）か、`{ "name": "...", "path": "...", "args": ["..."] }`（`name` と `args` は省略可）のどちらでも書ける。`name` は確認画面と起動ログに出す表示名で、省略時は `Get-DefaultName` がファイル・フォルダの末尾名か URL のホスト名で補う。
- 対話メニューでできるのは「番号で選んで起動」「新規作成」「削除」のみ。編集は JSON を直接書き換える。起動は必ず「中身を表示 → Y/N」を挟む。
- 起動対象の開き方は `Start-Target` が種類から自動判定する。`http(s)://` の URL と `.html` / `.htm` / `.pdf` のファイルは、既存ウィンドウのタブに吸収されないよう、既定のブラウザを `--new-window` 付きで直接起動して 1 件ごとに別ウィンドウで開く。既定のブラウザの実行ファイルは `AssocQueryString`（shlwapi）に https の関連付けを問い合わせて求める。レジストリの `UserChoice` を直接読まないのは、Windows 11 では `UserChoiceLatest` に移っており、旧キーに古い値（既定を変更する前のブラウザ）が残るため。特定できない場合（ストアアプリ版のブラウザなど）は `Start-Process` に任せるため、新規ウィンドウにはならない。`--new-window` は Chromium 系と Firefox で通じる前提。フォルダも同じ理由で `explorer.exe /n,"パス"` を使い、既存のエクスプローラー（別デスクトップにあるとデスクトップごと切り替わる）を再利用させない。それ以外は `Start-Process` に任せ、ファイルの場合は作業フォルダをそのファイルのあるフォルダにする。
- 仮想デスクトップの操作は公開 API がないため、`user32.dll` の `keybd_event` で Win+Ctrl+D（作成）/ Win+Ctrl+Left（戻る）を送出している。アプリのウィンドウは「起動時にアクティブなデスクトップ」に開くことに依存しているので、`$WaitPerApp` / `$WaitPerDesktop` / 作成後の 1200ms などの待ち時間は動作の一部であり、削ると別のデスクトップにウィンドウが開く。
- 最後の Win+Ctrl+Left は `デスクトップ数 - 1` 回だけ送る。実行開始時のデスクトップが右端にある前提で、そうでない場合は開始位置に戻らない。
- 起動後は「終了 / メニューに戻る」を尋ねる。スクリプト冒頭で `ELECTRON_NO_ATTACH_CONSOLE=1` を設定しているのは、`Code.exe` を直接起動すると起動元のコンソールに接続してログを出し続け、ツール終了後もコンソールウィンドウが閉じなくなるため。
## 編集時の注意

- [launchApps.ps1](src/launchApps.ps1) は UTF-8 (BOM 付き) + CRLF。`quickStart.bat` が Windows PowerShell 5.1 (`powershell`) で起動するため、BOM を落とすと日本語文字列が文字化けして構文エラーになる。ファイル全体を書き直した場合は BOM と CRLF が残っているか `file src/launchApps.ps1` で確認する。
- [quickStart.bat](src/quickStart.bat) は ASCII + CRLF。日本語を入れない。
- PowerShell 5.1 前提。入れ子の配列はパイプラインや `return` で平坦化されるため、プリセットの読み書きは `ArrayList` と `ConvertTo-Json -InputObject` で扱っている。
- プリセット JSON は BOM なし UTF-8 で読み書きする（`[IO.File]` を使用。5.1 の `Get-Content` / `Set-Content` の既定エンコーディングに頼らない）。
