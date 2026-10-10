# SwiftUI layout prototype

This DEV-45 experiment reads the hosted SwiftUI debug tree when Redline captures the screen. It is opt-in and compiled only in Debug. The demo fixtures do not pass their layout constants to the inspector. Tapping through the normal Redline picker compares accessibility text and bounds with runtime text nodes and their wrappers.

## Run

Build the RedlineDemo scheme in Debug on an existing iOS simulator. Add these launch arguments:

```text
-RedlineLayoutPrototype YES -RedlineLayoutActivation early
```

The demo sets `SWIFTUI_VIEW_DEBUG=287` in its App initializer for this mode. For launch-time activation, use `RedlineLayoutActivation external` and supply the environment variable in the scheme. `none` and `late` are negative controls; the UI test explicitly supplies `SWIFTUI_VIEW_DEBUG=0` for those modes. Late activation runs one second after the screen appears.

Tap the Redline button, then a sample. The annotation form shows a captured crop of only the component and its padding, with measured padding shaded. Surrounding frame space is excluded from the crop; frame dimensions remain below it. Red lines with end ticks on the top, right, bottom, and left show measured padding in points; nested padding can read `5 + 5 pt`. Side labels sit beside the cropped padding. The crop may be scaled for display, but its labels keep the original measurements.

Use the larger layers icon beside the component name to open its hierarchy. It has no visible container. Padding & frame has a separate chevron: collapse it to hide the captured component and measurement lines, or expand it to inspect them again. Selected padding stays under Included in note, and the written note is preserved. The preview starts expanded and remembers the chosen state during the session, including when another component is selected.

Tap a measurement line or its label to include that edge in the note; tap again to remove it. The thin line has an invisible touch area of at least 44 points. Selected edges highlight in the crop, and Included in note previews the context. Add note saves that context with the written note, so existing report and Mac readers receive it. Nothing is added automatically. A captured zero-distance edge can be selected; missing geometry stays unavailable.

Expand Layout details for readable Padding, Frame, Alignment, and flexible width and height rows, then Parent layout for stack spacing and surrounding settings. The card scrolls when needed and keeps its note buttons visible. It opens without the keyboard; selecting padding does not open one.

Cancel returns to picking; close annotate mode returns to the normal screen. Pass `-RedlineLayoutPrototype NO` to return to the regular demo.

## Verification

Run the demo scheme's `LayoutPrototypeTests` on one existing simulator with parallel testing disabled. The test covers four fresh app launches, explicit horizontal and top padding, two identical nested padding modifiers, fixed and flexible frames, stack spacing and alignment, priority, both duplicate-label positions, identical overlapping labels, synthetic accessibility text, and a repeat selection. Additional UI checks cover measurement-line selection and deselection away from the numeric label, saved note context, the layers icon and separate preview chevron, retained context and draft text after collapsing or viewing hierarchy, the remembered preview state for the next selection, large Dynamic Type, and a visible nested-frame sample in landscape. The fixture column is taller than the landscape viewport, so some other samples are offscreen. Screenshots remain in the test result bundle. Inspect captures in both simulator appearances; screenshots alone do not prove VoiceOver interaction.

Simulator review on 2026-10-10 passed four focused form tests, including the independent hierarchy and preview controls, draft and selection retention, large text, and landscape. Native captures show the larger unfilled icon and the compact collapsed form with retained context. The package suite passed all 238 tests; generic simulator Debug and Release kit builds and the Debug demo build passed, and the Release kit excluded the private activation symbol.

The prototype also writes `layout-tree-*.json`, `layout-nodes.txt`, and `layout-elements.json` to the app's Documents directory while enabled. These are local diagnostic captures and are not added to Redline reports.

## Interpretation

- `_UIHostingView._viewDebugData()` provides live nodes through an underscored SDK API. The prototype reflects `_ViewDebug.Data` storage and layout implementation types. This is not a stable public API contract.
- Text and bounds matching is experimental. Different-position duplicates can be distinguished; identical overlapping labels remain ambiguous. A unique text match without matching bounds is explicitly marked as an unverified candidate.
- Default padding keeps its declaration as System default. When the tree supplies inner and outer bounds, Measured padding separately shows their distance. The form crop and measured frame size use captured geometry, including an immediate background node when its layout node omits bounds; missing bounds are not borrowed from arbitrary ancestors. An unspecified frame bound remains distinct from a declared value.
- Only plain text selections are supported. Synthetic accessibility text without rendered geometry is excluded. Combined labels, custom layouts, localized or formatted text, transforms, scrolling, multiple windows, and other SDK versions require additional verification.
- Wrapper order is innermost first. Ancestor layouts are shown separately. The branch boundary is a prototype heuristic, not a reconstruction of the original Swift source expression.
- Simulator evidence establishes behavior only on the tested simulator runtime. Physical-device behavior is unverified.

## Research pointers

Apple's [LayoutSubview documentation](https://developer.apple.com/documentation/swiftui/layoutsubview) describes data available to a custom layout's own subviews. It does not expose an arbitrary selected view's modifier chain. [SwiftUIViewDebug](https://github.com/OpenSwiftUIProject/SwiftUIViewDebug) demonstrates the underscored hosted-tree API; [axe](https://github.com/k-kohey/axe) uses the debug activation environment variable for SwiftUI tree capture. These approaches motivated this experiment; neither is a guarantee of universal accessibility-to-view mapping.
