# Protocol notes (Phase 0)

정본: 리포 루트 `Core/Sources/AfterscreenCore/Protocol/` · `Support/Pairing.swift`

## Framing

- Header LE: `u8 type`, `u8 flags`, `u16 reserved=0`, `u32 payloadLength`
- JSON payloads use Swift Codable camelCase; `Data` → base64 string

## Pairing

- X25519 agree → HKDF-SHA256 (salt=transcript bytes, info=`afterscreen pairing`, 32 bytes)
- Transcript: each part length-prefixed with **big-endian** u32, then bytes
- MAC: HMAC-SHA256(key, label || transcript || extra)

## Smoke CLI

```text
dotnet run --project Afterscreen.Sender -- hello <host> <port>
dotnet run --project Afterscreen.Sender -- pair <host> <port> <6-digit-code>
```

페어링 키·senderID는 `%LOCALAPPDATA%\AfterscreenSender\` 에만 저장 (로그에 코드/키 금지).
