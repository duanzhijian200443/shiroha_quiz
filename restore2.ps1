$historyDir = "$env:APPDATA\Code\User\History"
$corruptedFiles = @(
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\ai_generator_screen.dart",
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\import_staging_screen.dart",
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\mock_exam_screen.dart",
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\paper_review_screen.dart",
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\practice_page.dart",
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\question_edit_screen.dart",
    "c:\Users\34331\shiroha_quiz\lib\ui\pages\question_list_screen.dart"
)

foreach ($file in $corruptedFiles) {
    $entriesFiles = Get-ChildItem -Path $historyDir -Filter "entries.json" -Recurse
    $targetEntryFile = $null
    foreach ($ef in $entriesFiles) {
        $content = Get-Content $ef.FullName -Raw -Encoding UTF8
        $encodedPath = "file:///c%3A" + $file.Substring(2).Replace('\', '/')
        if ($content -match $encodedPath) {
            $targetEntryFile = $ef
            break
        }
    }
    
    if ($targetEntryFile) {
        $json = Get-Content $targetEntryFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = $json.entries | Sort-Object timestamp -Descending
        
        $restored = $false
        foreach ($entry in $entries) {
            $backupPath = Join-Path $targetEntryFile.DirectoryName $entry.id
            if (Test-Path $backupPath) {
                # We want the latest backup that DOES NOT have the missing quote bug.
                # A quick way is to check if it has "gitHubFlavored" (which was added by my script),
                # if it doesn't have it, it is from BEFORE my script!
                $backupContent = Get-Content $backupPath -Raw -Encoding UTF8
                if (-not ($backupContent -match "gitHubFlavored.blockSyntaxes")) {
                    Set-Content -Path $file -Value $backupContent -Encoding UTF8 -NoNewline
                    Write-Host "Restored $file from $backupPath"
                    $restored = $true
                    break
                }
            }
        }
        if (-not $restored) {
            Write-Host "No valid backup found for $file"
        }
    } else {
        Write-Host "No history folder found for $file"
    }
}
