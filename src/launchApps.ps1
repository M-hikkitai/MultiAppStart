# ===== 設定 =====
$WaitPerApp        = 2   # アプリ1つ起動するごとの待ち秒数
$WaitPerDesktop    = 5   # 次のデスクトップへ移る前の待ち秒数（ウィンドウが開き切るのを待つ）
$PresetDir         = Join-Path $PSScriptRoot 'presets'
$BrowserExtensions = @('.html', '.htm', '.pdf')
$ArgExtensions     = @('.exe', '.bat')
# ================

Set-Location -Path $PSScriptRoot

# VS Code などの Electron アプリは起動元のコンソールに接続してログを出し続け、
# ツール終了後もコンソールウィンドウが閉じなくなるため、接続させない
$env:ELECTRON_NO_ATTACH_CONSOLE = '1'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VDKey {
    [DllImport("user32.dll")]
    static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    static void Combo(byte key) {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero); // Win
        keybd_event(0x11, 0, 0, UIntPtr.Zero); // Ctrl
        keybd_event(key,  0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        keybd_event(key,  0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
        keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }
    public static void NewDesktop() { Combo(0x44); } // Win+Ctrl+D
    public static void Left()       { Combo(0x25); } // Win+Ctrl+Left
}
public static class Assoc {
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern int AssocQueryString(int flags, int str, string assoc, string extra, System.Text.StringBuilder buf, ref uint size);
    public static string Executable(string assoc) {
        uint size = 1024;
        System.Text.StringBuilder buf = new System.Text.StringBuilder((int)size);
        return AssocQueryString(0, 2, assoc, null, buf, ref size) == 0 ? buf.ToString() : null; // 2 = ASSOCSTR_EXECUTABLE
    }
}
"@

# 既定のブラウザの実行ファイルを探す。レジストリの UserChoice は Windows の版によって
# 保存場所が変わり古い値が残るため、直接読まずに Windows の API に問い合わせる
$Browser = [Assoc]::Executable('https')
if (-not ($Browser -and $Browser -like '*.exe' -and (Test-Path -LiteralPath $Browser -PathType Leaf))) { $Browser = $null }

function Get-PresetFiles {
    if (-not (Test-Path -LiteralPath $PresetDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $PresetDir -Filter '*.json' -File | Sort-Object Name)
}

function Get-DefaultName($path) {
    if ($path -match '^https?://') {
        $uri = $null
        if ([uri]::TryCreate($path, [UriKind]::Absolute, [ref]$uri)) { return $uri.Host }
        return $path
    }
    $leaf = [IO.Path]::GetFileName($path.TrimEnd('\', '/'))
    if ($leaf) { return $leaf }
    return $path
}

# プリセットを読み込み、デスクトップごとの起動対象（Name / Path / Arguments）のリストにそろえる
function Read-Preset($file) {
    $json = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
    $desktops = New-Object System.Collections.ArrayList
    foreach ($d in @($json.desktops)) {
        $items = New-Object System.Collections.ArrayList
        foreach ($e in @($d)) {
            $name = $null
            if ($e -is [string]) {
                $path = $e
                $arguments = @()
            } else {
                $name = [string]$e.name
                $path = [string]$e.path
                $arguments = @($e.args | Where-Object { $_ })
            }
            if (-not $path) { throw "path が空の起動対象があります。" }
            if (-not $name) { $name = Get-DefaultName $path }
            [void]$items.Add([pscustomobject]@{ Name = $name; Path = $path; Arguments = [string[]]$arguments })
        }
        [void]$desktops.Add($items)
    }
    if ($desktops.Count -eq 0) { throw "desktops が空です。" }
    return ,$desktops
}

function Show-Preset($desktops) {
    for ($i = 0; $i -lt $desktops.Count; $i++) {
        Write-Host ("  デスクトップ{0}" -f ($i + 1)) -ForegroundColor Yellow
        foreach ($item in $desktops[$i]) {
            Write-Host ("    {0}" -f $item.Name) -ForegroundColor Green
            Write-Host ("      {0}" -f (@($item.Path) + $item.Arguments -join ' ')) -ForegroundColor Gray
        }
    }
}

function Start-Target($item) {
    $path = $item.Path
    $isUrl = $path -match '^https?://'
    $isFile = (-not $isUrl) -and (Test-Path -LiteralPath $path -PathType Leaf)

    if ($Browser -and ($isUrl -or ($isFile -and $BrowserExtensions -contains [IO.Path]::GetExtension($path).ToLower()))) {
        # 既存ウィンドウのタブに吸収されないよう、必ず新しいウィンドウで開く
        Start-Process -FilePath $Browser -ArgumentList @('--new-window', "`"$path`"")
        return
    }

    if ((-not $isUrl) -and (Test-Path -LiteralPath $path -PathType Container)) {
        # 既定の開き方だと別デスクトップにある既存のエクスプローラーが使われ、デスクトップごと切り替わってしまう
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/n,"{0}"' -f (Get-Item -LiteralPath $path).FullName)
        return
    }

    $params = @{ FilePath = $path }
    if ($isFile) { $params.WorkingDirectory = (Get-Item -LiteralPath $path).DirectoryName }
    $quoted = @($item.Arguments | ForEach-Object { if ($_ -match '\s' -and $_ -notmatch '^".*"$') { "`"$_`"" } else { $_ } })
    if ($quoted.Count -gt 0) { $params.ArgumentList = $quoted }
    Start-Process @params
}

function Start-Preset($desktops) {
    for ($i = 0; $i -lt $desktops.Count; $i++) {
        if ($i -gt 0) {
            # 新しい仮想デスクトップを作成（作成と同時にそこへ移動する）
            Write-Host "-> 新しい仮想デスクトップを作成" -ForegroundColor Gray
            [VDKey]::NewDesktop()
            Start-Sleep -Milliseconds 1200
        }

        Write-Host ("[デスクトップ{0}]" -f ($i + 1)) -ForegroundColor Yellow
        foreach ($item in $desktops[$i]) {
            Write-Host "   起動: $($item.Name)" -ForegroundColor Green
            try {
                Start-Target $item
            } catch {
                Write-Host "   失敗: $($_.Exception.Message)" -ForegroundColor Red
            }
            Start-Sleep -Seconds $WaitPerApp
        }

        if ($i -lt $desktops.Count - 1) {
            Start-Sleep -Seconds $WaitPerDesktop
        }
    }

    # 最初のデスクトップに戻る
    for ($i = 1; $i -lt $desktops.Count; $i++) {
        [VDKey]::Left()
        Start-Sleep -Milliseconds 400
    }
}

function New-Preset {
    $name = (Read-Host "新しいプリセットの名前").Trim()
    if (-not $name) {
        Write-Host "キャンセルしました。"
        return
    }
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.StartsWith('.')) {
        Write-Host "ファイル名に使えない文字が含まれています。" -ForegroundColor Red
        return
    }
    $file = Join-Path $PresetDir "$name.json"
    if (Test-Path -LiteralPath $file) {
        Write-Host "プリセット '$name' は既に存在します。" -ForegroundColor Red
        return
    }

    Write-Host "パスまたは URL を 1 件ずつ入力し、続けて表示用の名前を入力してください。空行で次のデスクトップへ、もう一度空行で完了です。" -ForegroundColor Cyan
    $desktops = New-Object System.Collections.ArrayList
    while ($true) {
        $items = New-Object System.Collections.ArrayList
        while ($true) {
            $path = (Read-Host ("デスクトップ{0} の起動対象" -f ($desktops.Count + 1))).Trim().Trim('"')
            if (-not $path) { break }
            $itemName = (Read-Host ("  名前（Enter で '{0}'）" -f (Get-DefaultName $path))).Trim()
            $arguments = @()
            if ($ArgExtensions -contains [IO.Path]::GetExtension($path).ToLower()) {
                $line = Read-Host "  引数（なければ Enter）"
                $arguments = @([regex]::Matches($line, '"([^"]*)"|(\S+)') | ForEach-Object {
                    if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
                })
            }
            if ($itemName -or $arguments.Count -gt 0) {
                $entry = [ordered]@{}
                if ($itemName) { $entry.name = $itemName }
                $entry.path = $path
                if ($arguments.Count -gt 0) { $entry.args = $arguments }
                [void]$items.Add($entry)
            } else {
                [void]$items.Add($path)
            }
        }
        if ($items.Count -eq 0) { break }
        [void]$desktops.Add($items.ToArray())
    }

    if ($desktops.Count -eq 0) {
        Write-Host "起動対象がないため、保存しませんでした。"
        return
    }

    if (-not (Test-Path -LiteralPath $PresetDir)) { [void](New-Item -ItemType Directory -Path $PresetDir) }
    $json = ConvertTo-Json -InputObject @{ desktops = $desktops.ToArray() } -Depth 5
    [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "プリセット '$name' を保存しました。" -ForegroundColor Cyan
}

function Select-PresetFile($files, $text) {
    $n = 0
    if ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) { return $files[$n - 1] }
    Write-Host "番号が正しくありません。" -ForegroundColor Red
    return $null
}

while ($true) {
    $files = Get-PresetFiles
    Write-Host ""
    Write-Host "保存済みプリセット:" -ForegroundColor Cyan
    if ($files.Count -eq 0) { Write-Host "  （なし）" }
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $files[$i].BaseName)
    }
    $choice = (Read-Host "番号=起動 / N=新規作成 / D=削除 / Q=終了").Trim()

    if ($choice -match '^[Qq]$') { exit 0 }

    if ($choice -match '^[Nn]$') {
        New-Preset
        continue
    }

    if ($choice -match '^[Dd]$') {
        if ($files.Count -eq 0) { continue }
        $file = Select-PresetFile $files (Read-Host "削除するプリセットの番号").Trim()
        if (-not $file) { continue }
        if ((Read-Host "プリセット '$($file.BaseName)' を削除しますか？ (Y/N)") -match '^[Yy]') {
            Remove-Item -LiteralPath $file.FullName
            Write-Host "削除しました。"
        } else {
            Write-Host "キャンセルしました。"
        }
        continue
    }

    $file = Select-PresetFile $files $choice
    if (-not $file) { continue }

    try {
        $desktops = Read-Preset $file
    } catch {
        Write-Host "プリセット '$($file.BaseName)' を読み込めません: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    Write-Host "プリセット '$($file.BaseName)' を以下の構成で起動します:" -ForegroundColor Cyan
    Show-Preset $desktops
    if ((Read-Host "起動しますか？ (Y/N)") -notmatch '^[Yy]') {
        Write-Host "キャンセルしました。"
        continue
    }

    Start-Preset $desktops
    Write-Host "すべての起動処理が完了しました。" -ForegroundColor Cyan
    if ((Read-Host "ツールを終了しますか？ (Y=終了 / N=メニューに戻る)") -match '^[Yy]') { exit 0 }
}
