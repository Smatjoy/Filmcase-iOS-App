# Filmcase iOS

`cd ios && xcodegen generate && open Filmcase.xcodeproj`. See `docs/ios_app_plan.md` for the plan and
`Spikes/README.md` for the USB spike.

## Targets

- `Filmcase`: the app. Embeds the widget extension.
- `FilmcaseWidgets`: the Live Activity (Lock Screen and Dynamic Island) for a push to the camera.
- `Shared/` is compiled into both, so they agree on `PushActivityAttributes`.

## Bundle ids for a device build

The app id is `$(FILMCASE_BUNDLE_ID)` and the widget extension's is `$(FILMCASE_BUNDLE_ID).widgets`
(an extension's id must start with its app's). To use your own ids override the ONE setting:

    xcodebuild -project Filmcase.xcodeproj -scheme Filmcase -destination 'generic/platform=iOS' \
      FILMCASE_BUNDLE_ID=dev.filmcase.app.ms build

That gives the app `dev.filmcase.app.ms` and the extension `dev.filmcase.app.ms.widgets`. Do not override
`PRODUCT_BUNDLE_IDENTIFIER` on the command line: it would give both targets the same id. In Xcode, change
`FILMCASE_BUNDLE_ID` in the project's build settings (or in `project.yml`) instead.
