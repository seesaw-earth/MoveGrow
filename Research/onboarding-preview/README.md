# Onboarding preview

The onboarding pictures (`MoveGrow/Features/Onboarding/OnboardingArt.swift`) are drawn with the app's baby
figure. This folder draws the same pictures outside the app, as SVG, so they can be looked at and tuned
without an Xcode build.

- `babyfigure.js`: a port of `MoveGrow/Features/Pose/BabyFigure.swift` to JavaScript. Same geometry
  (ellipsoids, tapered capsules, convex hulls, orthographic projection), same order of painting, same
  palette, the mat with its dots and soft shadows, the face, sprout and leg openings. Output is SVG markup.
  It has no dependencies, so it can also be the start of a 3D viewer for the website.
- `poses.js`: the onboarding's baby — `BabyFigure.restingPose`, the gentle kicking and waving loop, the
  turn about the mat's normal, and the mat (`OnboardingBaby` in Swift).
- `scenes.js`: the pictures as the app composes them: the camera pictures with the dashed guide (not yet /
  all set), the recorder and the videos from Photos, and the phone held above the baby.
- `make_assets.js`: writes every picture to `assets/*.svg`.

```bash
node make_assets.js                                    # SVG
for f in assets/*.svg; do rsvg-convert -z 3 "$f" -o "${f%.svg}.png"; done   # PNG @3x (librsvg)
```

When a pose, a view or a size changes in `OnboardingArt.swift`, change it here too (the numbers are the
same in both). Differences from the app: shadows are blurred by an SVG filter, and the leg openings are
drawn with clip paths instead of path intersection; the pictures agree to within a pixel or two.
