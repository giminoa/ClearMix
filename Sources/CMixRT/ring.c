#include "cmix_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Indices are free-running counters in frames; the mask maps them into the
// allocation. A free-running counter avoids the classic "full vs empty"
// ambiguity of wrapped head/tail indices.
struct cmix_ring {
    float *data;
    size_t capacity;  // frames, power of two
    size_t mask;
    uint32_t channels;
    _Atomic size_t write_index;
    _Atomic size_t read_index;
};

static size_t next_power_of_two(size_t value) {
    size_t result = 2;
    while (result < value) {
        if (result > (SIZE_MAX / 2)) {
            return 0;
        }
        result <<= 1;
    }
    return result;
}

cmix_ring *cmix_ring_create(size_t capacity_frames, uint32_t channels) {
    if (channels == 0) {
        return NULL;
    }
    size_t capacity = next_power_of_two(capacity_frames);
    if (capacity == 0) {
        return NULL;
    }
    cmix_ring *ring = calloc(1, sizeof(cmix_ring));
    if (ring == NULL) {
        return NULL;
    }
    size_t sample_count = capacity * (size_t)channels;
    if (sample_count / capacity != (size_t)channels) {
        free(ring);
        return NULL;
    }
    ring->data = calloc(sample_count, sizeof(float));
    if (ring->data == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity;
    ring->mask = capacity - 1;
    ring->channels = channels;
    atomic_store_explicit(&ring->write_index, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->read_index, 0, memory_order_relaxed);
    return ring;
}

void cmix_ring_destroy(cmix_ring *ring) {
    if (ring == NULL) {
        return;
    }
    free(ring->data);
    free(ring);
}

size_t cmix_ring_capacity(const cmix_ring *ring) {
    return ring->capacity;
}

uint32_t cmix_ring_channels(const cmix_ring *ring) {
    return ring->channels;
}

size_t cmix_ring_available_read(const cmix_ring *ring) {
    size_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    size_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    return write - read;
}

size_t cmix_ring_available_write(const cmix_ring *ring) {
    size_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    size_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    return ring->capacity - (write - read);
}

size_t cmix_ring_write(cmix_ring *ring, const float *src, size_t frames) {
    size_t available = cmix_ring_available_write(ring);
    if (frames > available) {
        frames = available;
    }
    if (frames == 0) {
        return 0;
    }
    size_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    size_t start = write & ring->mask;
    size_t first = ring->capacity - start;
    if (first > frames) {
        first = frames;
    }
    memcpy(ring->data + start * ring->channels,
           src,
           first * (size_t)ring->channels * sizeof(float));
    if (frames > first) {
        memcpy(ring->data,
               src + first * ring->channels,
               (frames - first) * (size_t)ring->channels * sizeof(float));
    }
    atomic_store_explicit(&ring->write_index, write + frames, memory_order_release);
    return frames;
}

size_t cmix_ring_read(cmix_ring *ring, float *dst, size_t frames) {
    size_t available = cmix_ring_available_read(ring);
    if (frames > available) {
        frames = available;
    }
    if (frames == 0) {
        return 0;
    }
    size_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    size_t start = read & ring->mask;
    size_t first = ring->capacity - start;
    if (first > frames) {
        first = frames;
    }
    memcpy(dst,
           ring->data + start * ring->channels,
           first * (size_t)ring->channels * sizeof(float));
    if (frames > first) {
        memcpy(dst + first * ring->channels,
               ring->data,
               (frames - first) * (size_t)ring->channels * sizeof(float));
    }
    atomic_store_explicit(&ring->read_index, read + frames, memory_order_release);
    return frames;
}

float *cmix_ring_write_ptr(cmix_ring *ring, size_t *frames) {
    size_t available = cmix_ring_available_write(ring);
    size_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    size_t start = write & ring->mask;
    size_t contiguous = ring->capacity - start;
    if (contiguous > available) {
        contiguous = available;
    }
    *frames = contiguous;
    return contiguous == 0 ? NULL : ring->data + start * ring->channels;
}

void cmix_ring_advance_write(cmix_ring *ring, size_t frames) {
    size_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    atomic_store_explicit(&ring->write_index, write + frames, memory_order_release);
}

float *cmix_ring_read_ptr(cmix_ring *ring, size_t *frames) {
    size_t available = cmix_ring_available_read(ring);
    size_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    size_t start = read & ring->mask;
    size_t contiguous = ring->capacity - start;
    if (contiguous > available) {
        contiguous = available;
    }
    *frames = contiguous;
    return contiguous == 0 ? NULL : ring->data + start * ring->channels;
}

void cmix_ring_advance_read(cmix_ring *ring, size_t frames) {
    size_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    atomic_store_explicit(&ring->read_index, read + frames, memory_order_release);
}

void cmix_ring_clear(cmix_ring *ring) {
    atomic_store_explicit(&ring->read_index, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->write_index, 0, memory_order_release);
}
