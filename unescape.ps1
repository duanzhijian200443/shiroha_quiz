$targetFiles = @(
    "ai_generator_screen.dart",
    "import_staging_screen.dart",
    "mock_exam_screen.dart",
    "paper_review_screen.dart",
    "question_edit_screen.dart"
)

foreach ($f in $targetFiles) {
    $path = "lib\ui\pages\$f"
    $content = (Get-Content $path -Raw -Encoding UTF8).Trim()
    if ($content.StartsWith('"') -and $content.EndsWith('"')) {
        $unescaped = ConvertFrom-Json $content
        [System.IO.File]::WriteAllText($path, $unescaped, [System.Text.Encoding]::UTF8)
        Write-Host "Unescaped $f"
    }
}
