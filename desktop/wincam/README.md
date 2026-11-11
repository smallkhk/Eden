# LiveChar Camera (Windows 11 virtual camera)

Media Foundation virtual camera, based on VCamSample by Simon Mourier (MIT, see LICENSE):
https://github.com/smourier/VCamSample

Changes for LiveChar:
- `VCamSampleSource/FrameGenerator.*` reads frames written by the LiveChar app instead of drawing a test card.
- `VCamSample/VCamSample.cpp` is a windowless helper that registers the camera while the app wants it.
- Own class ID, 1280x720, CPU sample path only.

Frame hand-off (header 64 bytes + BGRA rows, top-down):
`"LCVCAM1\0"`, u32 width, u32 height, u32 frame number, u32 reserved, u64 unix-ms time, padding to 64.
The app writes to the shared section `Local\LiveCharVCamFrame` (created by the helper), or, if that
is not available, to the file `%ProgramData%\LiveChar\vcam.frame`. The camera shows black when no
frame newer than 2 seconds is found.
