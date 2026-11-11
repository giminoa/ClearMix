// ClearMix realtime primitives.
//
// This header is intentionally C: the audio render callback must not touch the
// Swift runtime (no allocation, no ARC, no exclusivity checks).
#ifndef CMIX_RING_H
#define CMIX_RING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Single-producer / single-consumer ring buffer of interleaved float frames.
///
/// Exactly one thread may write and one (other) thread may read. No locks are
/// taken, no memory is allocated after `cmix_ring_create`.
typedef struct cmix_ring cmix_ring;

/// Creates a ring buffer. `capacity_frames` is rounded up to the next power of
/// two (minimum 2). Returns NULL on allocation failure.
cmix_ring *cmix_ring_create(size_t capacity_frames, uint32_t channels);
void cmix_ring_destroy(cmix_ring *ring);

size_t cmix_ring_capacity(const cmix_ring *ring);
uint32_t cmix_ring_channels(const cmix_ring *ring);

/// Frames currently available to the consumer.
size_t cmix_ring_available_read(const cmix_ring *ring);
/// Frames the producer may write right now.
size_t cmix_ring_available_write(const cmix_ring *ring);

/// Writes up to `frames` frames; returns the number actually written.
size_t cmix_ring_write(cmix_ring *ring, const float *src, size_t frames);
/// Reads up to `frames` frames; returns the number actually read.
size_t cmix_ring_read(cmix_ring *ring, float *dst, size_t frames);

/// Zero-copy producer access: returns a pointer to a contiguous writable block
/// and stores its length in `*frames`. Call `cmix_ring_advance_write` afterwards.
float *cmix_ring_write_ptr(cmix_ring *ring, size_t *frames);
void cmix_ring_advance_write(cmix_ring *ring, size_t frames);

/// Zero-copy consumer access, mirrored from the producer side.
float *cmix_ring_read_ptr(cmix_ring *ring, size_t *frames);
void cmix_ring_advance_read(cmix_ring *ring, size_t frames);

/// Drops all buffered frames. Only safe while no other thread is using the ring.
void cmix_ring_clear(cmix_ring *ring);

#ifdef __cplusplus
}
#endif

#endif /* CMIX_RING_H */
