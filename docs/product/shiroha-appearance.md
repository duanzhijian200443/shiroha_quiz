# Shiroha appearance and shared visual tokens

## Scope

The formal appearance presets are 浅色 (`light`), 深色 (`dark`) and 彩色
(`colorful`). All share one page structure and business behavior. Colorful and
light both have light brightness; preset identity comes from
`ShirohaThemeTokens.appearance`, never from brightness alone.

This contract governs the global theme, appearance selection, Today/training
local theme compatibility and primary-navigation colors. It does not redesign
all pages, change navigation or business state, or retire preserved capabilities.
The existing Today illustrations, composition and dimensions remain unchanged.
Older hardcoded decorations and Practice's local palette remain for bounded
future page-polish work; global theme adoption is not full visual closure.

## Palette

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
| featureNeutral | `#6B6D76` | `#B4B5BE` | `#626F83` |
| featureNeutralFill | `#F0F0F5` | `#33343D` | `#EDF3F9` |

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
only to colorful; light/dark retain their existing palette, bright grayscale
greeting, Category artwork treatment, card outline/shadow and native feedback.
The three icon replacements apply to all appearances. Colorful secondary text
reads the shared token with at least 4.5:1 contrast against its intended surface.

The greeting and Category illustrations retain their original objects and
dimensions. In colorful, a token-derived luminance filter preserves source alpha
and maps the existing grayscale art to surface/neutral-ink tones with a subdued primary
influence. Neutral banner/fold colors and existing dark Category modulation
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
`#575B69` / `#EAEAF0` in dark, and primary / white in colorful. These are filled
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

我的 → 外观设置 opens one mutually exclusive three-option chooser. Switching
immediately previews the new appearance through `globalThemeNotifier` and saves
the same canonical name with existing SettingsRepository `app_theme` storage.
While a save is pending all choices are disabled. Successful save retains the
preview. Failure invalidates the existing repository's optimistic cache,
restores the preceding runtime value even if Profile has been disposed, and
shows a safe retry message when the page is still mounted. No success is
reported for failed persistence; no automatic retry or corrective write occurs.

Startup normalizes missing, empty, unknown, malformed and historical `morandi`
values to light, without rewriting the stored value. An appearance-read failure
also falls back to light. `morandi` never aliases colorful. No new database
field, migration or generic settings-cache behavior is introduced.

## Local themes and validation

Today (also used by TaskCenter and bank detail) and training configuration
preserve the explicit preset, changing only their existing component-specific
shape/slider details. Untagged host themes retain a brightness-based grayscale
fallback; tagged light/colorful themes are never conflated. Primary navigation
reads the active theme's colors, retaining its three destinations, icons and
route structure.

Required deterministic coverage includes preset mapping, token/Material
consistency, contrast, local-wrapper preservation, selection and rollback,
single-flight saves, disposal, database close/reopen, fallback, navigation and
existing affected regressions. Actual application screenshots for Today,
AI 服务, 我的/appearance chooser and navigation in all three modes require
separate visual acceptance. Synthetic Widget-rendered screenshots are useful
evidence but never substitute for that runtime acceptance.
