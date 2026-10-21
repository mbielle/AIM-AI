# Pending interaction presentation extraction

`AIMPendingInteractionViews.swift` contains the 309-line presentation group previously embedded in `AIMConversationView.swift`:

- `AIMRemoteVisualApprovalCard`: visual provider/model selection and forwarding the existing decline/allow-once/remember decisions to `MainExperienceStore`.
- `AIMPendingApprovalCard`: pending authorization/question summary, responsive action buttons, busy state and question-sheet presentation.
- `AIMRemoteQuestionsSheet`: single/multiple-choice answers, free text, skip state, existing answer composition and submission callback.
- `AIMPendingSummaryHeight`: the private summary-height preference used by the card.

Only `AIMRemoteVisualApprovalCard` and `AIMPendingApprovalCard` changed from file-private to module-internal because `AIMConversationView` constructs them from the original file. The question sheet, preference key and member helpers remain private. No layout, state, action, text, accessibility identifier or authorization behavior was changed. The extracted block was compared byte-for-byte against the original after restoring those two access modifiers. The project uses explicit file entries; the new source has a file reference, group membership and a Sources build-phase entry.

`AIMConversationView.swift` decreased from 5,780 to 5,471 lines; the new file has 313 lines including imports. This is a limited separation of pending-interaction presentation, not completion of the large-view refactor. The original file still combines the conversation surface, markdown/message rendering, composer/media capture and panels, model picking and other presentation helpers. Its size and remaining coupled responsibilities are still a maintenance risk.

Validation for this move consists of Swift parsing, Xcode project/plist validation and a Simulator build-for-testing that compiles application and test targets. The move does not change layout, so the previously executed UI suite was not repeated solely for this extraction.

A subsequent independent model-picker extraction reduced the remaining conversation file to 4,822 lines; see `MODEL_PICKER_EXTRACTION.md` for that move and its evidence.
