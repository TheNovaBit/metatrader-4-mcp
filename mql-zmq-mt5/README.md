# mql-zmq (MT5-patched)

Drop-in `Include` set for **mql-zmq** (github.com/dingmaotu/mql-zmq) patched to compile under
recent **strict MetaTrader 5** MetaEditor builds, used by `mcp/ZeroMQ_Bridge.mq5`.

## Why this exists

Recent MetaEditor builds forbid implicit `char[]` ↔ `uchar[]` array conversions. Upstream
mql-zmq passes `char[]` buffers to `Mql\Lang\Native.mqh`'s `StringToUtf8(...,uchar&[],...)` /
`StringFromUtf8(const uchar&[])` and declares several `libzmq.dll` imports with `char&[]`. On a
2026-era MT5 build this produces ~26 `error 246: parameter convertion type 'char[]' to ...uchar[]`
errors. The fix makes the library **uchar-consistent** with `Native.mqh`.

## The patch (char → uchar only; no logic changed; ABI-safe)

`char`/`uchar` are both 1 byte, so changing DLL import signatures and byte buffers between them
does not change the marshalled bytes. Edited files (under `Include/Zmq/`):

- `Z85.mqh` — `zmq_z85_encode/decode`, `zmq_curve_keypair`, `zmq_curve_public` import params
  `char&[]`→`uchar&[]`; local Z85 buffers `char`→`uchar`.
- `SocketOptions.mqh` — get/set option string buffers `char`→`uchar`.
- `ZmqMsg.mqh` — `zmq_msg_gets` import param `const char&[]`→`const uchar&[]`.
- `Socket.mqh` — `zmq_bind/connect/unbind/disconnect/socket_monitor` import params
  `const char&[]`→`const uchar&[]`; local address buffers `char`→`uchar`.
- `Zmq.mqh` — `zmq_has` import param `const char&[]`→`const uchar&[]`.

`Include/Mql/` is upstream-unmodified (kept here only so this is a complete drop-in Include set).
`Native.mqh` is NOT modified.

## Install into an MT5 terminal

1. Copy `Include\Zmq\` and `Include\Mql\` → `<MT5_DATA>\MQL5\Include\`.
2. Copy the **64-bit** libs from the upstream download `mql-zmq\Library\MT5\` — `libzmq.dll` and
   `libsodium.dll` → `<MT5_DATA>\MQL5\Libraries\`. (MT5 is 64-bit; the MT4 `Library\MT4\` DLLs will
   NOT load. The DLL binaries are not committed here — get them from the upstream release.)
3. MT5 → Tools → Options → Expert Advisors → **Allow DLL imports**.
4. Compile `ZeroMQ_Bridge.mq5` (MetaEditor F7, or `metaeditor64.exe /compile:<path> /log:<log>`).
   Expected: `0 errors, 0 warnings`.

Verified clean against Pepperstone MT5, MetaEditor build (2026-06), via `/compile`:
`Result: 0 errors, 0 warnings`.
