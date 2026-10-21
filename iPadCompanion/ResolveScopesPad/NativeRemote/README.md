# NativeRemote control session

`RemoteSession` owns local Direct signaling, ICE/STUN, fingerprint-verified DTLS,
SCTP stream control and authenticated SRTCP feedback on a background serial queue.
It does not authenticate/decrypt incoming RTP, reorder packets, parse HEVC, wait for
keyframes, decode video, or provide any old media fallback. Those responsibilities
belong to `NativeMediaReceiver` and the native VideoToolbox/output pipeline.

The UDP socket demultiplexes media before creating any JavaScript typed array.
Incoming encrypted RTP goes directly to `onMediaDatagram(Data, UInt64)`; the timestamp
is local monotonic receive time in nanoseconds. STUN/DTLS and SRTCP remain in the
control adapter. Native SRTP must reject invalid authentication tags and enforce
replay policy. An opaque packet arriving through the callback is not an authenticated
video frame.

DTLS `EXTRACTOR-dtls_srtp` exports the peer's send-direction master key and salt via
`onSRTPKeys(Data, Data, Int)`. The advertised profile is standard
`SRTP_AES128_CM_HMAC_SHA1_80` (wire value 1, 16-byte master key, 14-byte master salt).
Keys stay in memory and are never included in status, diagnostics or resource files.
This negotiation does not transcode or change sender resolution/codec/bit depth.

Set callbacks before connecting. `queue` may be supplied to
`NativeMediaReceiver(queue: session.queue)` to process keys and incoming datagrams
inline without an extra queue hop. Call `connect(host:)`, `disconnect()`,
`sendNACK(mediaSSRC:sequences:)` and `requestKeyframe()` as needed.
NACK serializes standard RTCP Generic NACK through the negotiated authenticated
SRTCP session. Keyframe requests use the independently mapped sender stream-control
FlatBuffer type 4 through SCTP; PLI is additionally sent through authenticated SRTCP
when the receiver negotiated support and a media SSRC is known. Request counters
prove transmission only, not receipt of a new independently decodable frame.

SDP callbacks contain `media` with `videoPayloadTypes`, `rtxPayloadTypes`,
`rtxSSRCs`, base64 `parameterSets`, and `donlPresent`; stream-control metadata later
contains the original `timeline` and `config`. Preserve both callbacks. Local timing
is not calibrated source-to-glass latency.

Run `Tests/run-session-test.sh` on this Mac to compile an isolated Swift harness and
exercise actual two-peer SDP/ICE/DTLS/SCTP, directional native key export, unchanged
native raw-RTP delivery, authenticated NACK, sender IDR and PLI wires. Temporary
sources and executable are removed after the run. Only synthetic packets are used;
no live Resolve connection, footage or keys are recorded. This fixture does not
claim physical iPad playback success; that requires the integrated device run.

Protocol evidence and dependency provenance are recorded in `PROVENANCE.json`;
licenses are preserved in `THIRD_PARTY_NOTICES.txt` and vendor license comments.
