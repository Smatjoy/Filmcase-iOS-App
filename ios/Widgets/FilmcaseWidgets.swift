// The widget extension's entry point. It only hosts the push Live Activity.

import SwiftUI
import WidgetKit  // API: WidgetBundle, @main

@main
struct FilmcaseWidgetBundle: WidgetBundle {
    var body: some Widget {
        PushLiveActivity()
    }
}
