# CoreML Models

Drop your exported `.mlpackage` files here, then add them to the
`ResnetYoloTester` target in Xcode (drag into this group, check
"Copy items if needed" and target membership) — or run `xcodegen generate`
after adding them, since this project's `.xcodeproj` is generated from
`project.yml` and won't pick up new files on disk on its own.

See `export_to_coreml.ipynb` for the export code (mirrors the Android app's
ONNX export pipeline, targeting CoreML instead).

- `ROIDetector.mlpackage` — YOLO11n, single class (`CS`), imgsz 640. NMS baked
  in at export (conf 0.25 / iou 0.5). Architecture A only: proposes one
  top-1 region of interest on the full frame.
- `PADetector.mlpackage` — YOLO11m, single class (`pa`), imgsz **1024**. NMS
  baked in (conf 0.10 / iou 0.5). Architecture A only: run on the ROI crop
  (not the full frame), proposing candidate particles — capped at 100 boxes
  in `InferenceManager`, since that cap isn't baked into the model itself.
- `ResNetBinary.mlpackage` — ResNet-18, 2-class (`A`, `NA-OF`), 224x224,
  ImageNet normalization baked into the traced graph. Architecture A only:
  classifies each particle crop; if `P(A) < 0.4` the cascade stops and
  reports `NA-OF`.
- `ResNetSubtype.mlpackage` — ResNet-18, 3-class (`A-AM`, `A-C`, `A-CRO`),
  same input/normalization. Architecture A only: only runs when
  `P(A) >= 0.4`; falls back to the generic `A` label if its top confidence
  is below 0.25.
- `YOLONanoDetector.mlpackage` — YOLO11n, 7 classes (`A-AM`, `A-CF`, `A-COF`,
  `A-CP`, `A-CRO`, `NA-CS`, `NA-OF`), imgsz 640, NMS baked in (conf 0.25 /
  iou 0.5). Architecture B's model: a standalone, single-stage detector used
  as the direct on-device comparison point against the 4-stage cascade.

Xcode compiles `.mlpackage` resources to `.mlmodelc` automatically as part
of the build. `InferenceManager` (see `../ML/InferenceManager.swift`)
resolves the compiled models by filename at runtime via
`Bundle.main.url(forResource:withExtension:"mlmodelc")`, so no code changes
are needed as long as the filenames match `InferenceManager.ModelFile` — or
update those constants to match whatever you name the files.
