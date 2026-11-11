#include "cmix_stats.h"

#include <stdatomic.h>
#include <stdlib.h>

struct cmix_stats {
    _Atomic uint64_t underrun_frames;
    _Atomic uint64_t overrun_frames;
    _Atomic uint64_t frames_in;
    _Atomic uint64_t frames_out;
    _Atomic int64_t fill_frames;
};

cmix_stats *cmix_stats_create(void) {
    return calloc(1, sizeof(cmix_stats));
}

void cmix_stats_destroy(cmix_stats *stats) {
    free(stats);
}

void cmix_stats_add_underrun(cmix_stats *stats, uint64_t frames) {
    if (stats == NULL) return;
    atomic_fetch_add_explicit(&stats->underrun_frames, frames, memory_order_relaxed);
}

void cmix_stats_add_overrun(cmix_stats *stats, uint64_t frames) {
    if (stats == NULL) return;
    atomic_fetch_add_explicit(&stats->overrun_frames, frames, memory_order_relaxed);
}

void cmix_stats_add_frames(cmix_stats *stats, uint64_t input, uint64_t output) {
    if (stats == NULL) return;
    atomic_fetch_add_explicit(&stats->frames_in, input, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->frames_out, output, memory_order_relaxed);
}

void cmix_stats_set_fill(cmix_stats *stats, int64_t frames) {
    if (stats == NULL) return;
    atomic_store_explicit(&stats->fill_frames, frames, memory_order_relaxed);
}

void cmix_stats_reset(cmix_stats *stats) {
    if (stats == NULL) return;
    atomic_store_explicit(&stats->underrun_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->overrun_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->frames_in, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->frames_out, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->fill_frames, 0, memory_order_relaxed);
}

cmix_stats_snapshot cmix_stats_read(const cmix_stats *stats) {
    cmix_stats_snapshot snapshot = {0, 0, 0, 0, 0};
    if (stats == NULL) return snapshot;
    snapshot.underrun_frames = atomic_load_explicit(&stats->underrun_frames, memory_order_relaxed);
    snapshot.overrun_frames = atomic_load_explicit(&stats->overrun_frames, memory_order_relaxed);
    snapshot.frames_in = atomic_load_explicit(&stats->frames_in, memory_order_relaxed);
    snapshot.frames_out = atomic_load_explicit(&stats->frames_out, memory_order_relaxed);
    snapshot.fill_frames = atomic_load_explicit(&stats->fill_frames, memory_order_relaxed);
    return snapshot;
}
