# iOS accessibility audit (P9c)

Scope: every screen in `ios/App/Features/**` plus `RootView`. Method: code review against the
`ios-accessibility` and `axiom-accessibility` checklists. Nothing here was run on a device or
simulator (the audit was done on Linux); the lead's CI run and the list at the end cover that.

Severity: **High** blocks a task for some users, **Medium** degrades it, **Low** is polish.
Status: **Fixed** (in this change), **Open** (needs a Kit change or a device), **Check** (fixed in code, verify on device).

Shared helpers added in `Features/Shared/AccessibilitySupport.swift`: `announce(_:)`
(`AccessibilityNotification.Announcement`), `StatusLabel` (icon plus primary-colour text),
`AdaptiveStack` (row at normal sizes, column at accessibility sizes), `.secondaryText()`
(primary under Increase Contrast). `AppFont.swift` gained `.appLabelFont` / `.appMonoFont`,
which follow Bold Text.

## Findings

| Screen | Issue | Severity | Fix | Status |
|---|---|---|---|---|
| All | Async results (camera connected/lost) were silent unless focus happened to be on the pill. | High | `RootView` announces `pill.text` whenever `cameraModel.pill` changes. | Fixed |
| All | Status text in system green/orange/red on light backgrounds fails WCAG 4.5:1; colour was the styling signal. | Medium | `StatusLabel`: shaped icon carries the tint, text stays `.primary`. Used for onboarding errors, push results, validation, interrupted banner. | Fixed |
| All | Secondary text on tinted/quaternary fills had no Increase Contrast handling. | Low | `.secondaryText()` switches to `.primary` under Increase Contrast; applied to the spec titles, slot cells, row subtitles, counts, footnotes. | Fixed |
| All | Brand fonts (Archivo, Space Mono) ignore Bold Text. | Low | `.appLabelFont` / `.appMonoFont` read `legibilityWeight` and step the weight up (spec sheet, swatch, collection ordinal). | Fixed |
| Onboarding | A failed connect or field validation error appeared silently below the field. | High | `announce` on `state == .failed`, and on `lanURLError` / `tailscaleURLError` changes; error shown as `StatusLabel` (icon plus text, not red text alone). | Fixed |
| Onboarding | Bare `ProgressView` overlay while connecting had no label. | Medium | `.accessibilityLabel("Connecting")`. | Fixed |
| Onboarding | Trust prompt (medium detent) clipped at AX sizes; Cancel/Trust buttons side by side overflowed; title not a header. | High | Content in a `ScrollView`, buttons in `AdaptiveStack` with `.controlSize(.large)`, title `.isHeader`. | Fixed |
| Onboarding | Fingerprint (`AB:CD:...`) is read pair by pair, slowly. | Low | None possible without wording in the view. | Open (Kit, see questions) |
| Recipes list | Row was a `HStack`: thumbnail plus text squeezed at AX sizes; heart read separately. | Medium | `AdaptiveStack` column at AX, thumbnail capped at 96 pt, heart hidden (the model label already says "favourite"). | Fixed |
| Recipes list | Favourites toolbar toggle announced as plain button with value On/Off. | Medium | Added `.isToggle` trait. | Fixed |
| Recipes list | Unlabelled `ProgressView`s (initial load overlay, load-more footer). | Medium | Labels "Loading recipes" / "Loading more recipes". | Fixed |
| Recipes list | Search result count is never announced after typing or filtering. | Low | Needs model text. | Open (Kit, see questions) |
| Filter sheet | Checkmark image read as "checkmark" in addition to the selected trait. | Low | Hidden from VoiceOver. | Fixed |
| Filter sheet | Option row reads the name then a bare number ("Portra, 12"). | Low | Needs model text. | Open (Kit, see questions) |
| Recipe detail | Spec row read as two stops (label, value). | Medium | Row `.combine`, reads "Highlight, +2". | Fixed |
| Recipe detail | Disabled Send button gave no reason to VoiceOver (reason text was a separate stop). | High | The model's `sendBlockedReason` is now also the button's hint. | Fixed |
| Recipe detail | Spec section titles at 12 pt `.secondary`. | Low | `.secondaryText()`; already `.isHeader`. | Fixed |
| Collections list | Label "N recipes" read "1 recipes". Row also cramped at AX sizes; film simulations truncated to one line. | Medium | Inflected label, `AdaptiveStack`, line limit lifted at AX sizes. | Fixed (wording still in the view, see questions) |
| Collection detail | "Push to camera" sheet had no `NavigationStack`: its title, Auto-fill and Clear all toolbar items and any way to dismiss were missing. | High | Sheet wrapped in `NavigationStack`; `CollectionPushView` gets a Close button (disabled while a run is writing) and `interactiveDismissDisabled` during the run. | Fixed |
| Collection detail | Ordinal column used a fixed-size font. | Low | `.appMonoFont` (scales, follows Bold Text). | Fixed |
| Collection push | Row read twice (visible status text plus the icon's label merged by `.combine`). | High | Row is one element: label "C3, name", value `status.accessibilityText`. | Fixed |
| Collection push | "Clear" existed only as a swipe action plus an always-on custom action, even when the run was not editable. | Medium | Swipe action and VoiceOver action "Clear slot" (via `accessibilityActions`) offered only while `phase == .editing`. Reordering uses the system edit-mode move actions. | Fixed, Check |
| Collection push | Slot row `HStack` overflowed at AX sizes. | Medium | `AdaptiveStack`. | Fixed |
| Collection push | Interrupted/failed run was silent. | High | `announce` on `.interrupted` message and on `errorMessage`. | Fixed |
| Collection push | Completed run has no spoken summary. | Medium | Needs model text. | Open (Kit, see questions) |
| Collection push | Orange/red text for banner, validation, errors. | Medium | `StatusLabel`. | Fixed |
| Camera tab | Slot name and film simulation truncated (2 and 1 lines) at AX sizes. | Medium | Line limits lifted at AX sizes (label always had the full text). | Fixed |
| Camera tab | Backup row: text read as 2 stops, Restore button squeezed beside it at AX; button under 44 pt. | Medium | Text `.combine`, `AdaptiveStack`, `.controlSize(.large)`. | Fixed |
| Camera tab | Restore result used `.updatesFrequently` (wrong trait; nothing spoken). | High | Removed; `announce` on `backups.message` changes. "Backups" is now `.isHeader`. | Fixed |
| Camera tab | Connect button below 44 pt height. | Low | `.controlSize(.large)`. | Fixed |
| Bottom accessory pill | Icon identical in both states (green vs grey only). | Medium | Icon switches to `cable.connector.slash`; icon hidden from VoiceOver (button already says label, value, hint). | Fixed |
| Bottom accessory pill | `lineLimit(1)` truncates long status text at AX sizes (the accessory is height-constrained by the system). | Low | VoiceOver value carries the full text; visual truncation stays. | Open (system accessory) |
| Send sheet | Verified/failed result appeared after the slot grid VoiceOver was on vanished; nothing announced. | High | `announce(outcome.message)` on every outcome; "Backing up and writing C3" announced when the run starts. | Fixed |
| Send sheet | Result headline in system green/orange/red text. | Medium | `StatusLabel`. | Fixed |
| Send sheet | Recipe name not a header; result buttons under 44 pt. | Low | `.isHeader`, `.controlSize(.large)`. | Fixed |
| Send sheet | Partial-failure rows build "X did not take" in the view. | Low | Needs model text. | Open (Kit, see questions) |
| Settings | Forget-certificate icon button was about 20 pt, and merged into its row so the row read the button label ambiguously. | High | Button is its own stop, 44x44 pt, label includes the host; the text block is one stop. Redundant custom action removed. | Fixed |
| Settings | Secondary URL text. | Low | `.secondaryText()`. | Fixed |
| Reduce Motion | Animations (`pill`, push assignment, result) | Low | Already gated on `accessibilityReduceMotion`; the only transition is opacity. Tab bar minimise and the system sheet transitions are the system's and follow the setting. | Verified in code |
| Reduce Transparency | App uses `.fill` / `.quaternary` shapes, not materials; glass is system chrome (tab bar, accessory, toolbar) which adapts itself. | Low | Nothing to do. | Verified in code |
| Haptics | `.sensoryFeedback` is never the only signal (all results also have text). | Low | None. | Verified in code |

## Automated audit (CI and Mac)

`FilmcaseUITests` runs `performAccessibilityAudit()` on the demo recipes list and recipe detail. The first run, on Xcode 27.2 with an iPhone 17 simulator on iOS 26.5, reported:

| Issue | Cause | Resolution |
|---|---|---|
| Contrast "nearly passed" on list subtitles (film simulation) | System `.secondary` at subheadline size | **Fixed**: `secondaryText()` now uses 75 % of the primary colour (about 10:1), and full primary under Increase Contrast |
| Contrast failed on the lower spec-sheet rows and the `specSheet` container | Those elements extend under the translucent tab bar and its bottom accessory, and the audit measures them against the bar. The rows are full primary on the page | **Ignored, false positive**: contrast issues only for elements reaching into the bottom chrome (the tab bar plus about 60 pt) |
| Text clipped: "Search recipes" | The system search field's placeholder is drawn by UIKit | **Ignored, false positive**: clipped text only on `.searchField` |

Every other issue type still fails the test.

## Needs on-device VoiceOver check

1. Read order of every screen, in particular the push result (the announcement should not cut off the first read of the headline) and the Camera tab (pill, state, how-to card, slots, backups).
2. `announce(_:)` timing: the camera-connection announcement should not collide with the system "Camera connected" sheet or the Send sheet's own announcements.
3. Focus return after dismissing the filter sheet, send sheet, trust prompt and collection push sheet (should land on the control that opened it).
4. Collection push: reorder through the rotor "Actions" (system move up/down in edit mode), the "Clear slot" action, and the unassigned item `Menu`.
5. Trust prompt: fingerprint pronunciation, and that Cancel / Trust are reachable at AX5 inside the scroll view.
6. Bottom accessory pill: tap target height, label/value/hint, and visual truncation at AX sizes.
7. Dynamic Type up to AX5 on every screen: spec sheet, slot grid (columns collapse to one), collection push rows, Settings forget button, tab bar labels.
8. Bold Text: Archivo / Space Mono weight step-up looks right (heavy bold Space Mono is only the Bold face).
9. Increase Contrast and Reduce Transparency: glass chrome, the quaternary cards, the pill.
10. Voice Control "Show Names": "Restore C3, name", "Forget certificate for host", "Put in C3" are speakable; repeated Restore labels are unique per slot.
11. Switch Control: the Restore, Forget and Clear slot actions are all reachable without a swipe.
12. `performAccessibilityAudit()` first CI run (`AppUITests`): triage any reported issue; the tests exclude nothing.
