# SwiftUI layout prototype

This DEV-45 experiment reads the hosted SwiftUI debug tree when Redline captures the screen. It is compiled only in Debug and available from the demo's Layout tab. The demo fixtures do not pass their layout constants to the inspector. Tapping through the normal Redline picker compares accessibility text and bounds with runtime text nodes and their wrappers.

## Run

Build the RedlineDemo scheme in Debug and open the app normally on a device or existing simulator. Open Layout, tap Redline, then a sample. Runtime inspection activates in the App initializer before the first render. The Debug demo registers `RedlineLayoutInspection` as enabled without persisting that choice. This flag enables inspection independently of `RedlineLayoutPrototype`, which still opens the standalone fixture screen. Other host apps remain opt-in.

For a standalone fixture screen and explicit activation experiments, add these launch arguments:

```text
-RedlineLayoutPrototype YES -RedlineLayoutActivation early
```

The demo defaults to early activation and sets `SWIFTUI_VIEW_DEBUG=287` in its App initializer. An explicit activation mode overrides this default, preserving the negative controls. For launch-time activation, use `RedlineLayoutActivation external` and supply the environment variable in the scheme. `none` and `late` are negative controls; the UI test explicitly supplies `SWIFTUI_VIEW_DEBUG=0` for those modes. Late activation runs one second after the screen appears.

Tap the Redline button, then a sample. The annotation form shows a captured crop of only the component and its padding, with measured padding shaded. Surrounding frame space is excluded from the crop; frame dimensions remain below it. Red lines with end ticks on the top, right, bottom, and left show measured padding in points; nested padding can read `5 + 5 pt`. Side labels sit beside the cropped padding. The crop may be scaled for display, but its labels keep the original measurements.

Use the larger layers icon beside the component name to open its hierarchy. It has no visible container. Padding & frame has a separate chevron: collapse it to hide the captured component and measurement lines, or expand it to inspect them again. The snapshot and lines stay clipped to the disclosure while its height changes, so they cannot draw over the rows below it. Selected padding stays under Included in note, and the written note is preserved. The preview starts expanded and remembers the chosen state during the session, including when another component is selected.

Tap a measurement line or its label to include that edge in the note; tap again to remove it. The thin line has an invisible touch area of at least 44 points. Selected edges highlight in the crop, and Included in note previews the context. Add note saves that context with the written note, so existing report and Mac readers receive it. Nothing is added automatically. A captured zero-distance edge can be selected; missing geometry stays unavailable.

Expand Layout details for readable Padding, Frame, Alignment, and flexible width and height rows, then Parent layout for stack spacing and surrounding settings. The card scrolls when needed and keeps its note buttons visible. It opens without the keyboard; selecting padding does not open one.

Cancel returns to picking; close annotate mode returns to the normal screen. Pass `-RedlineLayoutPrototype NO` to return to the regular demo with its Layout tab.

## Verification

Run the demo scheme's `LayoutPrototypeTests` on one existing simulator with parallel testing disabled. The test covers four fresh app launches, explicit horizontal and top padding, two identical nested padding modifiers, fixed and flexible frames, stack spacing and alignment, priority, both duplicate-label positions, identical overlapping labels, synthetic accessibility text, and a repeat selection. Additional UI checks cover measurement-line selection and deselection away from the numeric label, saved note context, the layers icon and separate preview chevron, retained context and draft text after collapsing or viewing hierarchy, the remembered preview state for the next selection, large Dynamic Type, and a visible nested-frame sample in landscape. The fixture column is taller than the landscape viewport, so some other samples are offscreen. Screenshots remain in the test result bundle. Inspect captures in both simulator appearances; screenshots alone do not prove VoiceOver interaction.

Simulator review on 2026-10-10 passed four focused form tests, including the independent hierarchy and preview controls, draft and selection retention, large text, and landscape. Native captures show the larger unfilled icon and the compact collapsed form with retained context. The package suite passed all 238 tests; generic simulator Debug and Release kit builds and the Debug demo build passed, and the Release kit excluded the private activation symbol.

A collapse regression review on 2026-10-10 reproduced the snapshot drawing over the note context and details during the native disclosure transition. Clipping the disclosure confines the outgoing content to its shrinking area. Native simulator recordings and transition captures show three Flexible collapse/expand cycles with the lower rows unobscured. Both focused simulator tests passed. The repeated Flexible transition test also passed on an iPhone 17 Pro running iOS 27.0.1, retaining selected Top 7 pt context through all three cycles.

Normal-launch integration on 2026-10-10 passed a simulator flow from Recipes to Layout, inspection of Fixed with runtime 180 × 44 pt frame and horizontal 16 pt padding, return to Recipes, and annotation of a recipe summary. Three repeated Flexible preview toggles passed with the updated hosting-view traversal. All 238 package tests, Debug and Release kit builds, and Debug and Release demo builds passed; the Release kit excluded the private activation symbol. A signed Debug build was installed on the iPhone 17 Pro. The normal-launch device UI test could not run because iOS rejected the test runner's developer certificate, so the new tab interaction is verified on the simulator only.

The prototype also writes `layout-tree-*.json`, `layout-nodes.txt`, and `layout-elements.json` to the app's Documents directory while enabled. These are local diagnostic captures and are not added to Redline reports.

## Interpretation

- `_UIHostingView._viewDebugData()` provides live nodes through an underscored SDK API. The prototype reflects `_ViewDebug.Data` storage and layout implementation types. This is not a stable public API contract.
- Text and bounds matching is experimental. Different-position duplicates can be distinguished; identical overlapping labels remain ambiguous. A unique text match without matching bounds is explicitly marked as an unverified candidate.
- Default padding keeps its declaration as System default. When the tree supplies inner and outer bounds, Measured padding separately shows their distance. The form crop and measured frame size use captured geometry, including an immediate background node when its layout node omits bounds; missing bounds are not borrowed from arbitrary ancestors. An unspecified frame bound remains distinct from a declared value.
- Only plain text selections are supported. Synthetic accessibility text without rendered geometry is excluded. Combined labels, custom layouts, localized or formatted text, transforms, scrolling, multiple windows, and other SDK versions require additional verification.
- Capture reads visible hosting views with no nested visible hosting view. This avoids traversing a tab container's transition graph, which trapped on the tested iOS 27 runtime; ancestor settings stop at the captured host boundary.
- Wrapper order is innermost first. Ancestor layouts are shown separately. The branch boundary is a prototype heuristic, not a reconstruction of the original Swift source expression.
- Simulator evidence establishes behavior only on the tested simulator runtime. The iPhone 17 Pro check on iOS 27.0.1 establishes early activation and selected Flexible padding/collapse behavior on that device. Other physical-device configurations and selection types remain unverified.

## Research pointers

Apple's [LayoutSubview documentation](https://developer.apple.com/documentation/swiftui/layoutsubview) describes data available to a custom layout's own subviews. It does not expose an arbitrary selected view's modifier chain. [SwiftUIViewDebug](https://github.com/OpenSwiftUIProject/SwiftUIViewDebug) demonstrates the underscored hosted-tree API; [axe](https://github.com/k-kohey/axe) uses the debug activation environment variable for SwiftUI tree capture. These approaches motivated this experiment; neither is a guarantee of universal accessibility-to-view mapping.
