# Model picker presentation extraction

`AIMUnifiedModelPicker.swift` contains the 649-line coherent presentation group formerly at the end of `AIMConversationView.swift`: `AIMModelPickerItem`, the unified provider/model picker, its UIKit search field, the two private height preferences, private capability icons/details page, and its private card/nonempty-string helpers. The item and picker retain their existing module visibility; every private leaf/helper remains private. The block is unchanged byte-for-byte and is registered explicitly in the Xcode group and Sources phase.

This file move changes no model selection, loading, provider requests, admission, layout, action, accessibility identifier or string. `AIMConversationView.swift` decreases from 5,471 to 4,822 lines. It still combines message/markdown rendering, composer/media capture and multiple panels. Further separation remains a maintenance task; this is not completion of the large-view cleanup.

Qualification: the final Simulator application/UI-test build compiles this group and its existing consumers. A project-file UI check is run for the actual behavior added in this change; no full model-picker UI suite is repeated solely for the byte-identical move.
