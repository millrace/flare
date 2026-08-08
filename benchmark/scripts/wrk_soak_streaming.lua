-- streaming_tls soak: keep-alive GETs against a chunked streaming
-- endpoint over TLS (v0.10 operational gate).
--
-- The other soak workloads all pull a fixed 13-byte buffered body over
-- cleartext, so none of them exercise what this release actually
-- claims: TLS terminated on the reactor, several workers, and a
-- response delivered through the streaming write path.
--
-- Deliberately plain: no per-request scripting, because the point is a
-- long steady-state run whose RSS and fd curves are readable. What
-- makes it a streaming soak is the endpoint (/stream emits 16 chunked
-- writes) and the transport (https), not anything clever here.
--
-- The leak this is built to catch is a ChunkSource, its boxed
-- allocation, or the per-connection SSL that is not freed when a
-- streaming response finishes. Those show up as RSS drift over hours,
-- which is exactly what the observer samples.
wrk.method = "GET"
wrk.path = "/stream"
