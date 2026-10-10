# SwiftUI layout prototype

This DEV-45 experiment reads the hosted SwiftUI debug tree when Redline captures the screen. It is opt-in and compiled only in Debug. The demo fixtures do not pass their layout constants to the inspector. Tapping through the normal Redline picker compares accessibility text and bounds with runtime text nodes and their wrappers.

## Run

Build the RedlineDemo scheme in Debug on an existing iOS simulator. Add these launch arguments:

```text
-RedlineLayoutPrototype YES -RedlineLayoutActivation early
```

The demo sets `SWIFTUI_VIEW_DEBUG=287` in its App initializer for this mode. For launch-time activation, use `RedlineLayoutActivation external` and supply the environment variable in the scheme. `none` and `late` are negative controls; the UI test explicitly supplies `SWIFTUI_VIEW_DEBUG=0` for those modes. Late activation runs one second after the screen appears.

Tap the Redline button, then a sample. The note card shows runtime settings without opening the keyboard. Cancel returns to picking; close annotate mode returns to the normal screen. Pass `-RedlineLayoutPrototype NO` to return to the regular demo.

## Verification

Run the demo scheme's `LayoutPrototypeTests` on one existing simulator with parallel testing disabled. The test covers four fresh app launches, explicit horizontal and top padding, two identical nested padding modifiers, fixed and flexible frames, stack spacing and alignment, priority, both duplicate-label positions, identical overlapping labels, synthetic accessibility text, and a repeat selection. Screenshots remain in the test result bundle.

The prototype also writes `layout-tree-*.json`, `layout-nodes.txt`, and `layout-elements.json` to the app's Documents directory while enabled. These are local diagnostic captures and are not added to Redline reports.

## Interpretation

- `_UIHostingView._viewDebugData()` provides live nodes through an underscored SDK API. The prototype reflects `_ViewDebug.Data` storage and layout implementation types. This is not a stable public API contract.
- Text and bounds matching is experimental. Different-position duplicates can be distinguished; identical overlapping labels remain ambiguous. A unique text match without matching bounds is explicitly marked as an unverified candidate.
- Default padding records an unspecified inset, not a numeric resolved value. An unspecified frame bound is also distinct from a declared value.
- Only plain text selections are supported. Synthetic accessibility text without rendered geometry is excluded. Combined labels, custom layouts, localized or formatted text, transforms, scrolling, multiple windows, and other SDK versions require additional verification.
- Wrapper order is innermost first. Ancestor layouts are shown separately. The branch boundary is a prototype heuristic, not a reconstruction of the original Swift source expression.
- Simulator evidence establishes behavior only on the tested simulator runtime. Physical-device behavior is unverified.

## Research pointers

Apple's [LayoutSubview documentation](https://developer.apple.com/documentation/swiftui/layoutsubview) describes data available to a custom layout's own subviews. It does not expose an arbitrary selected view's modifier chain. [SwiftUIViewDebug](https://github.com/OpenSwiftUIProject/SwiftUIViewDebug) demonstrates the underscored hosted-tree API; [axe](https://github.com/k-kohey/axe) uses the debug activation environment variable for SwiftUI tree capture. These approaches motivated this experiment; neither is a guarantee of universal accessibility-to-view mapping.
