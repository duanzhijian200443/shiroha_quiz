# Shiroha appearance and shared visual tokens

## Scope

The appearance preference has two independent axes:

- Theme style: Paper (现代纸页), Grayscale (灰阶), Colorful (历史兼容).
- Display mode: Light, Dark, System.

`ShirohaAppearance` is a Flutter-free immutable preference with `style` and
`mode`. `ShirohaThemeTokens.appearance` retains this preference, including
System; `style` identifies the style and `brightness` identifies the currently
resolved Material brightness. Consumers use `isDark` / `isColorful` rather than
comparing the preference to a legacy preset. Style must never be inferred from
brightness. All combinations share page structure and business behavior.

### Modern Ink & Paper phase-one amendment

This authorized amendment supersedes the original three-option selection and
single-name persistence rules. It does not grant visual acceptance or rollout.
One existing `AppTheme` factory supplies `MaterialApp.theme`, `darkTheme` and
`themeMode`; Flutter's `ThemeMode.system` owns OS brightness changes. There is
no second theme system or manual platform brightness listener.

Paper is selectable and has an independent identity, but deliberately reuses
the existing grayscale light/dark palette until phase-two visual acceptance.
(This palette-reuse clause is superseded by the phase-two amendment below.)
Colorful Light preserves the historical colorful palette and decorations.
Colorful Dark, including System resolved dark, uses the existing grayscale dark
palette and decorations as a compatibility path; no new colorful visuals are
introduced. Returning to Light restores colorful behavior without losing style.

The composition-root `paperDefaultEnabled` switch remains false in phase one.
After formal acceptance and separately authorized rollout, enabling it gives
users with neither appearance key Paper + Light. Existing preferences, including
explicit historical Light, remain unchanged. Fonts, Today layout, business
navigation, training, RAG, database schema and Android build configuration are
outside this amendment.

This contract governs the global theme, appearance selection, Today/training
local theme compatibility and primary-navigation colors. It does not redesign
all pages, change navigation or business state, or retire preserved capabilities.
The existing Today illustrations, composition and dimensions remain unchanged.
Older hardcoded decorations and Practice's local palette remain for bounded
future page-polish work; global theme adoption is not full visual closure.

### Modern Ink & Paper phase-two amendment

This amendment supersedes only the phase-one palette-reuse clause above. It
keeps `paperDefaultEnabled` false and does not enable any new-user default or
rollout; all other phase-one rules remain in force.

Paper now owns an independent warm-paper palette inside the same `AppTheme`
factory. The grayscale compatibility columns keep their exact values.

| Role | Paper light | Paper dark |
|---|---|---|
| canvas | `#F7F4EE` | `#171A21` |
| surface | `#FFFEFA` | `#222630` |
| textPrimary | `#292D38` | `#F2EFE7` |
| textSecondary / outline | `#656877` | `#ABB0BF` |
| subtleFill / surfaceContainerHighest | `#EFEBE4` | `#2C303B` |
| primary action | `#394C73` | `#B9C8E7` |
| secondary / featureAi | `#6E5A93` | `#BCA9DC` |
| divider | `#DDDAD2` | `#363B48` |
| primary selected fill | `#E9ECF3` | `#2C3346` |
| secondary selected fill | `#EDE9F4` | `#332E42` |
| brandAccent / featureLibrary | `#40607F` | `#9FB6D4` |
| brandFill / featureLibraryFill | `#E4EAF0` | `#2A3342` |

Paper tertiary decoration equals the primary action; tertiary selected fill
equals subtleFill. Action foreground is white in Paper Light and `#171A21` in
Paper Dark. Success/correct, warning, the error family, secondary-container
foregrounds and disabled opacities are shared with the grayscale compatibility
palette; the remaining Material role wiring follows the same factory logic with
Paper values, and both Paper palettes keep the same accessible contrast targets
as phase one.

Paper joins Today illustration harmonization: banner and Category artwork
receive the existing alpha-preserving, token-derived luminance filter, mapping
the grayscale art onto the active Paper surface and neutral ink; welcome
caption and pill text read the shared textSecondary token. Objects, dimensions,
composition and card treatment are unchanged. Paper Light folded corners derive
from its own tokens (subtleFill, surface, surface, divider at 60% alpha);
Paper Dark keeps the shared neutral cold-gray ramp. Review decision: kept. Its
hue (226°) stays within about 4° of Paper Dark's own neutral hues (surface
223°, secondary text 225°) and its relative luminance (≈0.07–0.41) sits inside
the Paper Dark fill-to-muted band (≈0.03–0.44), so it reads as the card's
neutral corner shading. Introducing Paper-specific dark values first requires
real-device visual acceptance.

Assistant filled actions use primary / onPrimary in Paper (`#394C73` / white
light, `#B9C8E7` / `#171A21` dark) through assistantActionBackground /
assistantOnAction; the modal sidebar scrim keeps the compatibility values
(`#E0E3EE` 12% light, black 28% dark).

Settings-card and control boundary visibility is guarded by deterministic
floors asserted for both Paper palettes in the theme tests: outlineVariant vs
canvas ≥ 1.15, outlineVariant vs surface ≥ 1.2, surfaceContainerHighest vs
surface ≥ 1.1 and outline vs surface ≥ 3. Observed Paper contrast ratios are
divider/canvas 1.272 (light) / 1.555 (dark), divider/surface 1.384 / 1.352,
fill/surface 1.177 / 1.148 and outline/surface 5.476 / 6.984. Grayscale and
Colorful token values are unchanged by this amendment.

Real-device visual acceptance for Paper Light/Dark across Today, AI 服务,
我的/appearance chooser and navigation remains pending and is not granted by
this amendment.

## Desktop / tablet layout amendment (2026-10-25)

The appearance sheet offers an independent **界面布局** choice: **手机布局**
or **电脑 / 平板布局**, selectable on any device. Existing and absent preferences
keep the mobile layout. Changing layout preserves theme style and Light/Dark/System.
`ShirohaAppearance.layout` uses `mobile` / `workspace`. The existing version-1
appearance record accepts an optional `layout` field; absence means `mobile`,
and mobile saves omit the field for compatibility. Present null or unknown
values invalidate the record and use the existing read-only legacy fallback.
The existing Application save seam, single-row publication, single-flight preview,
rollback and portable-backup exclusion cover the whole preference. No settings
store, schema, dependency or parallel theme system is added.

The user's supplied desktop reference governs the workspace presentation. The
user explicitly authorized its navigation and Home calendar on 2026-10-25;
this supersedes the earlier three-destination/calendar-retirement requirements
for workspace layout only. Mobile keeps 今日 / 助手 / 我的 and its current Home.
Workspace navigation is 首页 / 资料库 / 学习空间 / 今日训练 / 题库 / 助手 / 设置.
Library, Spaces and Assistant reuse the existing workspace lifecycle owner and
its guards; Banks opens the existing data center; Settings reuses Profile.
Today training retains the Category, TrainingContent, new/review and single-plan
components and commands. The hero navigates to that surface; it never launches
an undifferentiated practice pool. Main page instances and the Home Assistant
draft survive navigation and layout changes. No automatic Agent turn is sent.

The user's proportional-scaling correction on 2026-10-25 supersedes the earlier
window-width rail/bottom-navigation and card-reflow rules. Workspace uses a wide
desktop canvas with a minimum design width of 1700 logical pixels. Below that
window width, the entire canvas scales uniformly by windowWidth / 1700; at wider
widths it stays at 1:1. Its design height is windowHeight / scale, retaining vertical
scrolling and the viewport's available height. Window resizing preserves the
expanded 248-design-pixel sidebar, four shortcut columns, the two activity/files
columns and the full toolbar rather than switching to a compact or mobile UI.
Fonts, spacing, artwork and controls share the same scale. Explicit accessibility
text-size preferences remain respected within the design canvas.

Scaling wraps the Navigator so routes, dialogs, tooltips, hit testing and semantic
bounds share one coordinate space. MediaQuery size, safe areas, keyboard insets
and display-feature bounds use design coordinates. The Navigator and page state
remain mounted across resizing and layout selection. Mobile uses its physical
logical viewport at 1:1 with its existing bottom navigation. Sidebar recent items
use real LibraryFile IDs; the workspace label is local-only and does not claim an
unsupported account switcher.

Each workspace destination exposes its name, button role, selected state and
activation action to assistive technology. Tooltip overlay anchors remain outside
excluded decorative semantics so visible hints retain a reachable traversal
parent. Navigation must preserve accessibility while hovering and changing pages.

Workspace Home has a bounded sea-view hero, four responsive shortcut cards,
learning activity and recent-files panels, and an Assistant draft entry. Content
is capped at 1440 design pixels. Shortcut cards use four columns at inner width
>= 940, two at >= 500, then one. Activity/files use two columns at >= 900 with
ordinary text scaling and otherwise stack in one vertical scroll surface. These
component widths refer to the design canvas, not the reduced physical viewport;
shrinking the workspace window therefore does not trigger their reflow thresholds.
The hero artwork is cropped from the user-provided reference with explicit
permission; text and controls are live Flutter widgets. All colors, interaction
states and typography use the existing theme and shared token factory.

The calendar shows local-date **review-log entry counts** for the current month
and previous eleven months, ending today. It does not claim distinct completed
questions, correct-answer rate or a streak. Summary labels distinguish learning
days in that window, review entries, current catalog question count and **this
week's** recorded StudyActivity duration. Duration is never inferred from counts;
partial and unavailable remain explicit. Recent files use the existing recent
catalog ordering and createdAt, labelled 添加于, not a fabricated last-opened or
updated time. Search covers the current bank catalog and at most twenty recent
files, with its scope shown in the UI. No full-text/global search is implied.

These geometry and IA rules replace earlier unchanged-layout clauses only for
this bounded workspace increment. Other destination pages retain their existing
functional UI for subsequent batches; UI-RWD-1 is not app-wide visual closure.

## Palette

The table's `light` / `dark` columns are the Grayscale light/dark compatibility
palettes; Paper's palette is the phase-two amendment table above, which reuses
the success/warning/error and secondary-container foreground roles below.
`colorful` is Colorful Light. The legacy `AppTheme.getTheme`, `lightTheme`,
`darkTheme`, `colorfulTheme` adapters retain these exact palettes.

| Role | light | dark | colorful |
|---|---|---|---|
| canvas | `#F7F7FA` | `#191A20` | `#F7F8F9` |
| surface | `#FFFFFF` | `#24252B` | `#FFFFFF` |
| textPrimary | `#303238` | `#EAEAF0` | `#303238` |
| textSecondary / outline | `#6B6D76` | `#B4B5BE` | `#596670` |
| subtleFill | `#F0F0F5` | `#33343D` | `#EEF2F4` |
| primary action | `#545864` | `#D2D4DC` | `#526979` |
| secondary / featureAi | `#7866A5` | `#B4A3CF` | `#7052A3` |
| tertiary decoration | `#545864` | `#D2D4DC` | `#94612F` |
| divider | `#E8E8EE` | `#3B3C45` | `#DFE5E9` |
| primary selected fill | `#F0F0F5` | `#33343D` | `#EBF0F3` |
| secondary selected fill / featureAiFill | `#EEE8FA` | `#37303F` | `#E8DCF5` |
| tertiary selected fill | `#F0F0F5` | `#33343D` | `#F6EDE2` |
| on primary selected fill | `#545864` | `#EAEAF0` | `#495F6F` |
| on secondary selected fill | `#68578F` | `#D6C8EA` | `#634391` |
| on tertiary selected fill | `#545864` | `#EAEAF0` | `#805524` |
| success / correct | `#397552` | `#9AD5B2` | `#397552` |
| warning | `#8A641F` | `#E5C18A` | `#8A641F` |
| error / incorrect | `#BA3540` | `#FFB4AB` | `#BA3540` |
| error container | `#FFEDEE` | `#5B252B` | `#FFEDEE` |
| on error container | `#7D1B25` | `#FFDAD6` | `#7D1B25` |
| brandAccent / featureLibrary | `#3286A2` | `#80AFC1` | `#197B9E` |
| brandFill / featureLibraryFill | `#DDF3FA` | `#293A42` | `#D7EEF7` |
| featureNeutral | `#6B6D76` | `#B4B5BE` | `#596670` |
| featureNeutralFill | `#F0F0F5` | `#33343D` | `#EEF2F4` |

Primary/secondary/tertiary action foreground is white in light/colorful and
`#191A20` in dark. Error foreground is white in light/colorful and `#381015`
in dark. Ordinary icons use textPrimary in grayscale presets and primary in
colorful by default; neutral Profile/settings icons use featureNeutral, AI uses
featureAi and learning/library uses featureLibrary with their paired bases.
Disabled foreground/fill use
textPrimary at 38%/12% opacity. Feedback colors retain their semantics and
must also be identified through text/icons where the existing UI requires it.

Colorful blue and container foregrounds are darker than the initial design
suggestion to keep normal text at least 4.5:1 against its intended canvas,
surface or action fill. Palette, Material component themes and the typed
ThemeExtension share one ColorScheme. Layout continues to use DesignTokens.
Unspecified Material roles must not reintroduce the historical high-saturation
cyan/purple scheme into neutral primitives. Light/dark retain neutral page
areas and navigation while allowing the explicitly defined subdued functional
accents. Colorful uses a muted steel-blue primary; its shared primary consumers
inherit that accent without a separate hardcoded Today palette.

## Today visual polish

Today preserves the existing page order, geometry, illustration assets,
composition, typography sizes, statistics, Category carousel and route behavior.
Its summaries, training entries, links and active navigation use one primary
accent family with neutral surfaces; no rainbow feature coding or new visual
focal point is introduced. Existing feedback semantics and other pages' explicit
feature accents remain unchanged. Color/style refinements in this section apply
only to colorful; grayscale light/dark retain their existing palette, bright
grayscale greeting, Category artwork treatment, card outline/shadow and native
feedback. Paper-specific deviations are enumerated in the phase-two amendment.
The three icon replacements apply to all appearances. Colorful secondary text
reads the shared token with at least 4.5:1 contrast against its intended surface.

The greeting and Category illustrations retain their original objects and
dimensions. In colorful and Paper, a token-derived luminance filter preserves
source alpha and maps the existing grayscale art to surface/neutral-ink tones;
colorful light keeps a subdued primary influence in that mapping. Neutral banner/fold colors and existing dark Category modulation
are retained at the shared token boundary without introducing a page palette.

Colorful Today surface cards share a 14-pixel radius, divider at 45% for their
outline, and ColorScheme shadow at 4% (18-pixel blur, 6-pixel vertical offset).
Category artwork keeps its existing 18-pixel shape. Colorful outlines are
painted in the foreground so they do not change child padding or geometry.
No global Widget rebuild is implied.

Parse-task and training-configuration actions reproduce the user-supplied SVG
geometry using Flutter painting. The Assistant primary-navigation identity uses
the same custom four-point star in both selected and unselected states. These
three glyphs use a 24×24 canvas and 1.5-pixel round cap/join stroke, inheriting
theme/state colors. System add/home/person/calendar/chevron/close and ordinary
utility glyphs remain system icons. Existing hit targets and callbacks remain.
Header actions retain tooltips. Colorful local hover/pressed/focus colors derive
from the active icon token at 6%/12%/10%, with a visible keyboard focus outline on
IconButton controls; disabled controls retain disabled foreground and no active
overlay. Native Material interaction feedback is retained without scale motion.

## Profile hierarchy and feature-token consumers

Profile keeps its existing card/list structure, routes, groups, dimensions,
spacing and content. The avatar uses the soft brand base and icon as a focal
point. The learner badge uses subtleFill and textSecondary with semibold text,
so it does not compete with the name. Wrong-book, backup and appearance icons
stay neutral; AI is purple-gray and File Library is blue-gray. All functional
entry icons retain their existing 21-pixel glyphs and 38-pixel bases. Card
outline/shadow, separators, arrows and body/caption contrast remain shared.

AI feature colors reuse ColorScheme secondary/container roles already consumed
by AI service icons and Profile. Only the library/brand pair adds backing
colors to the existing ThemeExtension; avatar, library entry and heatmap share
it. Neutral features reuse the existing textSecondary/subtleFill. No independent
per-page palette or unused study/date feature role is introduced.

The heatmap retains the exact date calculation, 12×7 cells, record source,
statistics and count thresholds (zero, 1–9, 10–29, 30–59, 60+). Zero uses the
existing divider color (72% opacity in dark). Nonzero shades interpolate the
divider toward brandAccent at 30%, 55%, 78%, and 100%; light intensity darkens
and dark intensity brightens. All empty cells remain identical; no learning
records are synthesized by production code. Fixtures cover empty/recorded
states, monotonic intensity, all appearances, narrow/wide windows and enlarged
text. Functional glyph/base contrast targets at least 3:1; ordinary/key text
continues to target 4.5:1. Today/Assistant/navigation are regression surfaces,
with no page-structure or illustration redesign in this pass.

## Assistant color hierarchy

Assistant retains its page structure, starter-card functional colors, routes,
composer behavior and the existing 900-pixel modal/persistent-sidebar breakpoint.
Its white cards sit over a restrained diagonal canvas gradient: surface toward
canvas at 35%, ending at canvas toward subtleFill at 50%. The header uses the
gradient's start color. No new illustration or large saturated background is added.

The Agent avatar, New Conversation button and Send/Stop button share
assistantActionBackground / assistantOnAction: `#707482` / white in light,
`#575B69` / `#EAEAF0` in dark, primary / white in colorful, and primary /
onPrimary in Paper (`#394C73` / white light, `#B9C8E7` / `#171A21` dark). These are filled
action roles, not ordinary text colors; foreground contrast is at least 4.5:1.
Send/Stop explicitly supplies its foreground so global ordinary-icon colors
cannot conceal the glyph. Disabled colors retain the existing shared roles.
Composer shadow opacity is 6%; sidebar dates and space counts use textSecondary.

The narrow modal sidebar keeps its dismiss/interaction behavior with a softer
scrim: `#E0E3EE` at 12% in light, black at 28% in dark and primaryContainer at
12% in colorful. Both the main shell and standalone Assistant consume this role;
wide persistent sidebars retain no scrim. The modal background is still blocked
while the sidebar is open. Untagged host themes retain their Material defaults.

## Selection and persistence

我的 → 外观设置 opens the existing sheet with two mutually exclusive groups:
主题风格 (现代纸页 / 灰阶 / 彩色（历史兼容）) and 显示模式
(浅色 / 深色 / 跟随系统). Changing one axis preserves the other. The sheet
presents Paper as an optional appearance with immediate preview and states that
Grayscale Light remains the default; it scrolls at constrained heights and
introduces no new business route. The Profile row shows both selected labels.

Switching immediately previews the complete preference through the typed
`globalThemeNotifier` and saves through `AppearanceSettingsService` and
`AppearanceSettingsPort`, implemented by SettingsRepository. While a save is
pending all six choices are disabled. Successful save retains the preview.
Failure removes only the appearance cache entry and restores both preceding
runtime axes even if Profile has been disposed, with a safe retry message when
still mounted. No success, automatic retry or corrective write follows failure.

SettingsRepository stores one JSON row in existing `app_settings`:
`app_appearance = {"version":1,"style":"paper|grayscale|colorful",
"mode":"light|dark|system"}` (strings are individual enum values, not pipes).
One SQLite row publishes both axes atomically; its cache updates only after the
write succeeds. No schema migration, new column or generic-cache change exists.

Read precedence is valid version-1 `app_appearance`, then legacy `app_theme`:

| Existing setting | Preference |
|---|---|
| `light` | Grayscale + Light |
| `dark` | Grayscale + Dark |
| `colorful` | Colorful + Light (existing visuals) |
| Empty/unknown/malformed/`morandi` | Grayscale + Light |
| Neither key, rollout switch false | Grayscale + Light |
| Neither key, formally enabled rollout | Paper + Light |

Reads never write migration/default values or overwrite the legacy key. An
explicit selection saves the versioned record; legacy bytes remain unchanged.
Malformed/unknown-version/invalid-axis versioned records remain untouched and
fall back to legacy, or Grayscale + Light when no legacy value exists. Their
presence never triggers the new-user Paper default. Startup read failure also
falls back to Grayscale + Light without rewriting storage. `morandi` never
aliases Colorful. A valid versioned choice survives restart and database reopen,
independent of changes to the rollout switch.

Both `app_theme` and `app_appearance` remain UI-local B0 exclusion keys. Portable
snapshots scrub them; raw rollback snapshots retain them. This extends the
existing exclusion rule without altering package format, credentials or restore
ownership. Portable backup is not an appearance synchronization mechanism.

Phase two is implemented through `AppTheme.themeFor(appearance,
Brightness.light/dark)` supplying both palettes and
`AppTheme.themeMode(appearance)` for mode selection. The Paper amendment
changes only the Paper branch inside that same factory and Paper-sensitive
semantic tokens, with ColorScheme / ThemeData / ThemeExtension aligned; no
parallel palette authority exists. Layout continues to use the existing
DesignTokens.

## Local themes and validation

Today (also used by TaskCenter and bank detail) and training configuration
preserve the explicit style and requested mode, changing only their existing component-specific
shape/slider details. Untagged host themes retain a brightness-based grayscale
fallback; tagged styles are never conflated, including System-mode preferences. Primary navigation
reads the active theme's colors, retaining its three destinations, icons and
route structure.

Required deterministic coverage includes legacy migration and read-only fallback,
rollout-vs-history defaults, versioned atomic writes and failed-write cache
invalidation, Paper/Grayscale light/dark resolution, the Paper phase-two
palette with its boundary-contrast floors and illustration harmonization, live
System changes in the real app Widget tree, preserved Colorful compatibility,
token/Material consistency, contrast, local-wrapper preservation, selection and
rollback, single-flight saves, disposal, database close/reopen, fallback,
navigation and existing affected regressions. Actual application screenshots for Today,
AI 服务, 我的/appearance chooser and navigation in supported style/brightness
combinations (including the new Paper Light/Dark palette) require separate
visual acceptance. Synthetic Widget-rendered screenshots are useful evidence
but never substitute for that runtime acceptance.
