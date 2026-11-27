# Mac → Windows port map

큰 흐름은 `Sender/`(Mac) 구현을 먼저 보고 가져온다. Windows 전용 추측 패치보다 이식 우선.

## Brought over (this pass)

| Mac | Windows |
|-----|---------|
| `Encode/FrameGate.swift` | `Encode/FrameGate.cs` + StreamLoop offer/take |
| `Encode/RateControl.swift` | `Encode/RateControl.cs` (SW starts at `Floor`) |
| `FrameStreamer` `inFlight < 2` | `Connection.QueuedFrames` + gate `busy` |
| `VideoEncoder` ForceKeyFrame (VT) | HW-only `CodecApi.RequestKeyframe`; SW waits for GOP |
| No keyframe-per-drop | Removed drop→RequestKeyframe |
| MF sample lifetime | `ProcessInput` owns sample — do not Dispose after accept |
| `fallBackToBC1` | SW MFT unsafe → tile-only when QSV prove fails (no soft hybrid) |
| QSV prove | System-memory NV12 first; handle `MF_E_TRANSFORM_STREAM_CHANGE` |

## Next to port

1. `FrameStreamer` outbox + async video completion
2. Wire `RateControl.Update` to TCP send-buffer samples
3. `TileEncoder` motion=.video / settleDelay timing (not dirty-share only)
4. DXGI texture input path (optional; system-mem QSV works)

## Do not invent

- Soft resolution/bitrate caps without `EncoderCapacity` / `RateControl` analogue
- Full BC7 while waiting for video picture
- Per-drop ForceKeyFrame on SW MFT
