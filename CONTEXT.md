# Overlook

A macOS WebRTC KVM client for PiKVM-class devices (including the GL.iNet Comet). This context covers the client's streaming, input, and device-control domain.

## Language

**Codec Preference**:
The operator's client-side choice of video codec for a stream — Auto, H.265, or H.264 — with Auto as the default. A preference, not a guarantee.
_Avoid_: video format (that's the device-side enum), codec setting

**Video Format**:
The device-side codec enum (`H264 = 0`, `H265 = 1`) the client sends in the Watch Request; the device's encoder follows whatever the client asks for.
_Avoid_: codec preference

**Watch Request**:
The Janus request a client sends to start receiving a stream. Carries the Video Format; the device follows the client — the client never edits persistent device config.

**Negotiated Codec**:
The codec actually flowing after SDP negotiation and any fallback — what a status surface should display. May differ from the Codec Preference.
_Avoid_: current codec, active format

**Fallback**:
The automatic downgrade from H.265 to H.264 when the offer lacks H.265 or the first-frame watchdog fires. Always visible in the status surface as "H.264 (fallback)" — never silent.
_Avoid_: downgrade (as a UI-facing word)

**Operator-Initiated Connect**:
A connection the operator explicitly triggers (picking a device, hitting reconnect, changing the Codec Preference). Always retries H.265 fresh — the operator's action is the fallback reset.

**Automatic Reconnect**:
A connection re-established without operator action (stream drop, device blip). Honors any remembered Fallback for the app session rather than retrying H.265.
