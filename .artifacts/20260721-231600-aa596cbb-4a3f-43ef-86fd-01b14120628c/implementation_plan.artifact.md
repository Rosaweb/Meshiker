# Fix Gesture Blocking of 'MAP' Button

The 'MAP' button and other map controls are currently blocked because the `PageView` and its edge-swipe `GestureDetector` overlays in `MainNavigationScreen` cover the entire screen or capture gestures that should reach the map.

I will redesign the navigation overlay to use a "CSS-like" approach: the `PageView` will only contain the side panels, and the central area (where the map is) will be a transparent "hole" that does not capture any gestures.

## Proposed Changes

### UI Component

#### [main_navigation_screen.dart](file:///C:/Users/user/AndroidStudioProjects/Meshiker/lib/ui/main_navigation_screen.dart)

- Wrap the `PageView` in a `LayoutBuilder` to accurately calculate dimensions.
- Modify the `pages` list in `build` to replace `const IgnorePointer(child: SizedBox.expand())` with a widget that allows gestures to pass through to the map.
- Adjust the edge-swipe `Positioned` detectors:
    - They currently use `HitTestBehavior.translucent` but they cover a fixed width.
    - I will ensure they only capture gestures when the panels are closed or being opened.
- Use `IgnorePointer` on the `PageView` itself when on the map page, OR use a custom `HitTest` logic.
- **Key Change**: Instead of a full-screen `PageView` where one page is a "hole", I will use a `Stack` where the side panels are `Positioned` and animated, leaving the center truly empty of overlays.

> [!NOTE]
> The user suggested a container-based approach without transparent layers. I will implement a system where side panels are positioned off-screen and slid in, ensuring the center is never covered by a transparent `PageView` layer.

```dart
// Conceptual change for MainNavigationScreen
Stack(
  children: [
    MapScreen(...),
    // Side Panels (Settings, Waypoints, etc.)
    // Only these will capture gestures when expanded
    _AnimatedSidePanel(
      align: Alignment.centerLeft,
      child: settingsPage,
      ...
    ),
    _AnimatedSidePanel(
      align: Alignment.centerRight,
      child: wpManagerPage,
      ...
    ),
  ]
)
```

## Verification Plan

### Automated Tests
- I will run `analyze_file` on `main_navigation_screen.dart` to ensure no syntax errors.

### Manual Verification
- I will verify the logic of the new layout to ensure that when panels are closed, the central region (from `edgeSwipeWidth` to `width - edgeSwipeWidth`) is completely free of any `GestureDetector` or `IgnorePointer` that could block the map.
- I will check that the `MAP` button (located at the bottom center) is now reachable.
