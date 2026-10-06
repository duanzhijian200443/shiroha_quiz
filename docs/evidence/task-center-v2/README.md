# TaskCenter V2 Widget visual evidence

These PNGs render the production `TaskCenterScreen` and read-only
`TaskCenterDetailSheet` with the injected `TaskCenterFake` from
`test/support/task_center_fakes.dart`. They are Flutter Widget render captures,
not generated mockups or captures of private application data.

Filename prefixes record logical width, theme and text scale. Pixel ratio is 1.
The 390 captures are 390×844, the 360 capture is 360×720 and the 1024 capture is
1024×768. The Widget matrix also exercises each size with Light/Dark and
1.0/1.3/2.0 scales, all four tabs, and scrollable detail content. At large text
scales, tabs scroll horizontally and cards/details scroll vertically; viewport
cropping does not imply a RenderFlex overflow.

| Capture | Purpose |
|---|---|
| [390 Light list](390-light-1.0-pendingReview.png) | Single-row tabs, long filename, neutral cards and list CTA |
| [390 Light detail](390-light-1.0-detail.png) | Read-only facts, duration and explicit copy control |
| [390 Dark list](390-dark-1.0-pendingReview.png) | Theme adaptation |
| [390 Dark detail](390-dark-1.0-detail.png) | Theme adaptation for the modal |
| [360 Dark 2.0 list](360-dark-2.0-pendingReview.png) | Large text, horizontal tabs and vertical list scrolling |
| [1024 Light list](1024-light-1.0-pendingReview.png) | Bounded content width on desktop |

Fixture: one queued, two pending-review, one completed and one failed record;
pending cards have 22 questions and one warning. Filename, timestamp, trace and
154-second duration are synthetic test inputs. The event formatter uses an
injected UTC+8 conversion; production uses the system local timezone. The
detail-only fixture trace is `trace-current`. No provider, saved key, source
document, application database or OCR request is used.

Windows reproduction (from the repository root, using the installed Flutter SDK):

```powershell
$env:B5_VISUAL_EVIDENCE = '1'
$taskCenterFlutterRoot = Split-Path (Split-Path (Get-Command flutter).Source)
$env:B5_MATERIAL_FONT = Join-Path $taskCenterFlutterRoot 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
flutter test --no-pub --concurrency=1 test/ui/task_center/task_center_screen_test.dart
```

The helper loads Windows Microsoft YaHei and the SDK's Material icon font;
removes the debug banner; captures the full MaterialApp including the modal
overlay through a RepaintBoundary; and temporarily enables real shadow paint
only for the capture, restoring the test painting invariant in `finally`.
Generated files are under `.dart_tool/task-center-v2-visual/`.

Visual comparison with the supplied gray reference checks title hierarchy,
decorative document/search graphic, neutral segmented tabs, rounded cards,
subtle separators/shadows and separated detail/operation areas. The layout
retains real Application counts/eligibility; reference numbers and dates are
not production constants. The independent read-only detail intentionally has
no list business buttons. These fixtures do not replace device/runtime or
independent Reviewer acceptance.
