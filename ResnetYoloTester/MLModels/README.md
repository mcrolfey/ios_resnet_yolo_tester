# CoreML Models

Drop your exported `.mlpackage` files here, then add them to the
`ResnetYoloTester` target in Xcode (drag into this group, check
"Copy items if needed" and target membership).

- `YOLOv11nDetector.mlpackage` — YOLOv11n object/ROI detector. Export with
  NMS baked in so Vision returns `VNRecognizedObjectObservation`s directly.
- `ResNetClassifier.mlpackage` — ResNet image classifier used as the second
  stage of Architecture A.

Xcode compiles `.mlpackage` resources to `.mlmodelc` automatically as part
of the build. `InferenceManager` (see `../ML/InferenceManager.swift`)
resolves the compiled models by filename at runtime via
`Bundle.main.url(forResource:withExtension:"mlmodelc")`, so no code changes
are needed as long as the filenames match `InferenceManager.ModelFile`
(`YOLOv11nDetector` / `ResNetClassifier`) — or update those constants to
match whatever you name the files.
