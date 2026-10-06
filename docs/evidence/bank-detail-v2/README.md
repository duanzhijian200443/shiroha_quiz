# Bank detail V2 Widget evidence

These PNGs are raw Flutter renders of the production `BankDetailScreen`,
captured by `test/ui/pages/bank_detail_screen_test.dart` through a
RepaintBoundary. They use a synthetic runtime bank name and an injected empty
Answer Completion query, making all six real entries visible. They are not AI
mockups, device screenshots or captures of private application data.

| Capture | Logical size | Theme / text scale | View |
|---|---|---|---|
| [Phone top](390-light-1.0-top.png) | 390×844 | Light / 1.0 | Header, practice and special training |
| [Phone management](390-light-1.0-management.png) | 390×844 | Light / 1.0 | Scrolled to both management entries |
| [Dark top](390-dark-1.0-top.png) | 390×844 | Dark / 1.0 | Same body with dark palette |
| [Dark management](390-dark-1.0-management.png) | 390×844 | Dark / 1.0 | Scrolled management section |
| [Narrow window](520-light-1.3-top.png) | 520×720 | Light / 1.3 | Narrow-window layout fixture |
| [Wide layout](1024-light-1.0-top.png) | 1024×768 | Light / 1.0 | Centered, bounded single column |

Pixel ratio is 1. OS chrome/status bars are absent. Microsoft YaHei and the
installed Flutter SDK's Material icon font supply readable local fixture
captures. The full matrix exercises 360×720, 390×844, 520×720 and 1024×768,
Light/Dark, 1.0/1.3/2.0 text scales, long Chinese names and every card's scroll
reachability/minimum 48-pixel hit area. Screenshots temporarily enable real
shadow painting and restore the test framework's painting invariant in `finally`.

Reference comparison:

- The dynamic bank title, subtitle, three groups, six single-column entries,
  neutral icon tiles, rounded surfaces, chevrons and subdued menu follow the
  supplied V2 design. Names and business data remain runtime values.
- The header reuses the existing local paper/pencil asset rather than adding
  the design's book-stack resource. Its restrained opacity keeps it decorative;
  it is excluded from semantics and hit testing, and omitted at large text scale.
- Phone/window heights require scrolling to management; entries are not shrunk
  to force a full-page design mockup into one viewport. Top/management captures
  preserve raw frames. Dark surfaces and large text follow the same body.
- Delete is a functional More-menu item with the original destructive confirmation
  and Application command. The page has no timer switch; ordinary Practice uses
  its existing false default. Per the 2026-10-06 user decision the Pomodoro
  capability is intentionally suspended rather than deleted: production exposes
  no user-visible Pomodoro entry anywhere — this switch was the only caller
  passing `isPomodoroActive: true` — while `PracticePage.isPomodoroActive`, its
  timer/UI branches, the Pomodoro session persistence path and the
  `pomodoro_sessions` history remain in place but unreachable. Restoring the
  capability requires a separate task and acceptance.

Windows capture recipe from the repository root:

```powershell
$env:BANK_DETAIL_VISUAL_EVIDENCE = '1'
$bankDetailFlutterRoot = Split-Path (Split-Path (Get-Command flutter).Source)
$env:BANK_DETAIL_MATERIAL_FONT = Join-Path $bankDetailFlutterRoot 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
flutter test --no-pub --concurrency=1 test/ui/pages/bank_detail_screen_test.dart
```

Generated captures are under `.dart_tool/bank-detail-v2-visual/`.
The ordinary practice navigation tests inspect the actual pushed route factory
before mounting Practice, preserving its bank/filter/commands/ordinary-context
handoff without starting a repository session read. Browse and Answer Completion
navigation mount their existing screens over fake queries. No application start,
private database, provider, saved key or source document is needed.

Focused regression command:

```powershell
flutter test --no-pub --concurrency=1 test/ui/pages/bank_detail_screen_test.dart test/dm_d1e_destructive_confirmation_test.dart test/answer_completion_ui_acceptance_test.dart test/ui/pages/p6_supplemental_answer_activation_test.dart test/ui/training/training_configuration_widget_test.dart test/architecture_boundary_test.dart
```

These captures and mechanical regressions do not replace independent review or
device/runtime acceptance. The governing product truth remains in
`docs/product/home-training-v3.md`; this directory only contains visual evidence.
