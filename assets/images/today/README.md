# Today reference illustrations

The two PNGs are decorative assets for the supplied `今日首页重构_UI.png` reference.
They contain no interface text or application data. Runtime text, counts and
navigation remain Flutter widgets. Both were produced with the built-in
`image_gen` tool using the supplied image as a reference, rather than by embedding
a screenshot of the interface.

`welcome-landscape.png` prompt:

> Use case: precise-object-edit. Reference is a mobile UI screenshot. Produce ONLY the grayscale landscape illustration filling the greeting banner in this reference, extracted and reconstructed as a standalone rectangular 3.5:1 wide asset. No rounded corners, no phone, no UI, no lettering, no greeting, no streak pill or text. Preserve precisely the composition of this banner: soft pale gray cloudy sky and layered mountains, small shrubs along bottom, white sun just right of center, two small birds above, gray seated cat viewed from behind on windowsill at about 72% of width, curved tail to right, stacked books and leafy plant at right edge, gray vertical window frame at extreme right. Left half mostly pale quiet cloudy scenery for live text overlay. Match reference monochrome cool-neutral low contrast editorial illustration. Full bleed. Do not generate a whole screen.

`paper-pencil.png` prompt:

> Use case: background-extraction. From reference mobile UI extract/reconstruct ONLY the small paper-and-pencil decorative illustration in the bottom '模考与试卷' card. Standalone transparent PNG illustration of two overlapping slightly tilted pale gray paper sheets with subtle gray horizontal lines and a diagonal graphite pencil pointing down-left in front. Same quiet low contrast grayscale shading, same angles and composition as reference. No words, no icons, no phone, no UI, no card backdrop, no calendar. Actual transparent background. Objects occupy most of canvas.


## Category card illustrations

`category-math.png` and `category-english.png` were generated with the built-in
`image_gen` tool. Category names and training names remain live Flutter text.
The decorative `Aa` in the English illustration is not application content.
Saved Category Visual preferences override keyword-based defaults. Generic and
computer categories reuse the local paper illustration; the computer preset adds
a code symbol. Dark mode modulates the art and uses a theme-aware text scrim.

`category-math.png` prompt:

> Create a single wide 3:1 grayscale editorial learning illustration background for a mobile app category card, softly shaded paper illustration, elegant neutral silver white charcoal, matching a minimalist study app. No UI, no border, no rounded corners, NO TEXT or letters or numbers. Left 35 percent mostly empty light gray softly textured paper for runtime title overlay. Right 65 percent a detailed open textbook in foreground, stack of closed books, triangle geometry ruler, small pencil cup, botanical leaves, thin mathematical coordinate curve on the wall behind. Objects fill lower right and reach almost full height, subtle shadows, gentle daylight. Not a photo, not flat icons. Output project asset.

`category-english.png` prompt:

> A wide 3:1 background illustration for a minimalist learning app. Monochrome silver gray white, soft paper editorial illustration with subtle depth and delicate shadows. Left 40% light nearly empty gray for interface text later. Right side fills with elegant open books, a small stack of flashcards, upright vocabulary card with only 'Aa', pencil and botanical leafy sprig. No other text, no UI, no frames. Neutral gentle daylight, sophisticated restrained grayscale, objects at lower right fill most of card height.
