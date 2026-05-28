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
        $content = Get-Content $ef.FullName -Raw
        $encodedPath = "file:///c%3A" + $file.Substring(2).Replace('\', '/')
        if ($content -match $encodedPath) {
            $targetEntryFile = $ef
            break
        }
    }
    
    if ($targetEntryFile) {
        $json = Get-Content $targetEntryFile.FullName -Raw | ConvertFrom-Json
        $entries = $json.entries | Sort-Object timestamp -Descending
        
        $restored = $false
        foreach ($entry in $entries) {
            $backupPath = Join-Path $targetEntryFile.DirectoryName $entry.id
            if (Test-Path $backupPath) {
                $backupBytes = [System.IO.File]::ReadAllBytes($backupPath)
                $backupContent = [System.Text.Encoding]::UTF8.GetString($backupBytes)
                if (-not ($backupContent.Contains([char]0xFFFD))) {
                    [System.IO.File]::WriteAllText($file, $backupContent, [System.Text.Encoding]::UTF8)
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
