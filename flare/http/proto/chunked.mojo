"""Sans-I/O framing for ``Transfer-Encoding: chunked`` request bodies.

RFC 9112 sec 7.1. Two questions the server reactor needs answered, both
pure functions over a byte buffer:

- :func:`scan_chunked_end` -- has the whole body arrived yet? The
  reactor cannot use ``Content-Length`` to size a chunked request, so
  without this it has no completeness signal at all and treats the
  request as finished the moment the headers land.
- :func:`decode_chunked_body` -- turn the framed bytes into the body the
  handler sees, plus any trailer fields.

Kept in the sans-I/O sublayer so both the server reactor and any future
client sharing can use it without either importing the other's
transport code. No sockets, no allocation beyond the output buffer.

Chunk-size lines are hex, optionally followed by ``;ext=val``
parameters, which are skipped per RFC 9112 sec 7.1.1. Trailer fields
after the terminating chunk are walked over so the end offset is
correct, but not surfaced -- no inbound caller needs them yet.
"""

from std.collections import List


comptime CHUNKED_INCOMPLETE: Int = -1
"""``scan_chunked_end``: more bytes needed."""
comptime CHUNKED_MALFORMED: Int = -2
"""``scan_chunked_end``: the framing is invalid; reject with 400."""


@always_inline
def _lower(b: UInt8) -> UInt8:
    if b >= UInt8(65) and b <= UInt8(90):
        return b + UInt8(32)
    return b


def _matches_at(
    buf: Span[UInt8, _], pos: Int, needle: Span[UInt8, _], limit: Int
) -> Bool:
    """Case-insensitive compare of ``needle`` against ``buf[pos:]``."""
    if pos + len(needle) > limit:
        return False
    for k in range(len(needle)):
        if _lower(buf[pos + k]) != _lower(needle[k]):
            return False
    return True


def header_says_chunked(buf: Span[UInt8, _], headers_end: Int) -> Bool:
    """True when the header block declares ``Transfer-Encoding: chunked``.

    A raw byte scan rather than a ``HeaderMap`` lookup: the reactor has
    to answer this *before* it parses, and the minimal-parser path
    (``skip_header_decode_for_short_requests``) never builds a
    ``HeaderMap`` at all.

    Matches the field name case-insensitively and looks for ``chunked``
    anywhere in the value. RFC 9112 sec 7.1 requires chunked to be the
    final encoding, so any list containing it means chunked framing on
    the wire.
    """
    var name = String("transfer-encoding").as_bytes()
    var want = String("chunked").as_bytes()
    var n = headers_end
    var i = 0
    while i < n:
        if _matches_at(buf, i, name, n):
            var p = i + len(name)
            if p < n and buf[p] == UInt8(58):  # ':'
                var line_end = p
                while line_end + 1 < n:
                    if buf[line_end] == UInt8(13) and buf[
                        line_end + 1
                    ] == UInt8(10):
                        break
                    line_end += 1
                var q = p + 1
                while q + len(want) <= line_end:
                    if _matches_at(buf, q, want, line_end):
                        return True
                    q += 1
                return False
        # Advance to the next header line.
        var e = i
        var found = False
        while e + 1 < n:
            if buf[e] == UInt8(13) and buf[e + 1] == UInt8(10):
                found = True
                break
            e += 1
        if not found:
            return False
        i = e + 2
    return False


@always_inline
def _hex_val(b: UInt8) -> Int:
    """Hex digit value, or -1 when ``b`` is not a hex digit."""
    if b >= UInt8(48) and b <= UInt8(57):
        return Int(b) - 48
    if b >= UInt8(97) and b <= UInt8(102):
        return Int(b) - 87
    if b >= UInt8(65) and b <= UInt8(70):
        return Int(b) - 55
    return -1


def scan_chunked_end(buf: Span[UInt8, _], start: Int, max_body: Int) -> Int:
    """Return the offset one past a complete chunked body.

    Walks the chunk-size lines without copying any payload. Returns
    ``CHUNKED_INCOMPLETE`` when more bytes are needed,
    ``CHUNKED_MALFORMED`` on invalid framing or when the decoded size
    would exceed ``max_body``, otherwise the absolute end offset
    (after the terminating chunk and its trailer section).

    ``max_body`` is checked against the running decoded total, not the
    wire total, and is checked *during* the walk -- a chunked upload
    must not be allowed to grow the read buffer past the configured
    limit before anyone notices.
    """
    var n = len(buf)
    var pos = start
    var decoded_total = 0
    while True:
        # chunk-size [ chunk-ext ] CRLF
        var line_end = -1
        var i = pos
        while i + 1 < n:
            if buf[i] == UInt8(13) and buf[i + 1] == UInt8(10):
                line_end = i
                break
            i += 1
        if line_end < 0:
            return CHUNKED_INCOMPLETE
        var size = 0
        var digits = 0
        var j = pos
        while j < line_end:
            var c = buf[j]
            if c == UInt8(59):  # ';' -- chunk extensions, ignored
                break
            var v = _hex_val(c)
            if v < 0:
                return CHUNKED_MALFORMED
            size = size * 16 + v
            digits += 1
            if size > max_body:
                return CHUNKED_MALFORMED
            j += 1
        if digits == 0:
            return CHUNKED_MALFORMED
        var data_start = line_end + 2
        if size == 0:
            # Terminating chunk: optional trailer fields, then CRLF.
            var t = data_start
            while True:
                if t + 1 >= n:
                    return CHUNKED_INCOMPLETE
                if buf[t] == UInt8(13) and buf[t + 1] == UInt8(10):
                    return t + 2
                # Skip one trailer line.
                var k = t
                var found = -1
                while k + 1 < n:
                    if buf[k] == UInt8(13) and buf[k + 1] == UInt8(10):
                        found = k
                        break
                    k += 1
                if found < 0:
                    return CHUNKED_INCOMPLETE
                t = found + 2
        decoded_total += size
        if decoded_total > max_body:
            return CHUNKED_MALFORMED
        # data CRLF
        var next_pos = data_start + size + 2
        if next_pos > n:
            return CHUNKED_INCOMPLETE
        if buf[data_start + size] != UInt8(13) or buf[
            data_start + size + 1
        ] != UInt8(10):
            return CHUNKED_MALFORMED
        pos = next_pos


def decode_chunked_body(
    buf: Span[UInt8, _], start: Int, mut out: List[UInt8]
) raises -> Int:
    """Append the decoded body to ``out``; return the end offset.

    Assumes :func:`scan_chunked_end` already accepted this buffer, so
    framing errors here raise rather than being reported as a status.
    Trailer fields are skipped; use :func:`decode_chunked_trailers` if
    the caller wants them.
    """
    var n = len(buf)
    var pos = start
    while True:
        var line_end = -1
        var i = pos
        while i + 1 < n:
            if buf[i] == UInt8(13) and buf[i + 1] == UInt8(10):
                line_end = i
                break
            i += 1
        if line_end < 0:
            raise Error("chunked: truncated size line")
        var size = 0
        var j = pos
        while j < line_end:
            var c = buf[j]
            if c == UInt8(59):
                break
            var v = _hex_val(c)
            if v < 0:
                raise Error("chunked: bad hex in size line")
            size = size * 16 + v
            j += 1
        var data_start = line_end + 2
        if size == 0:
            var t = data_start
            while t + 1 < n:
                if buf[t] == UInt8(13) and buf[t + 1] == UInt8(10):
                    return t + 2
                var k = t
                var found = -1
                while k + 1 < n:
                    if buf[k] == UInt8(13) and buf[k + 1] == UInt8(10):
                        found = k
                        break
                    k += 1
                if found < 0:
                    raise Error("chunked: truncated trailer")
                t = found + 2
            raise Error("chunked: truncated terminator")
        if data_start + size > n:
            raise Error("chunked: truncated chunk data")
        for k in range(size):
            out.append(buf[data_start + k])
        pos = data_start + size + 2
