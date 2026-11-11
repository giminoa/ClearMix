// ClearMix realtime counters.
//
// The render callback updates these; the UI and the command line tool read
// them from another thread. Plain integers would be a data race, a lock would
// be forbidden on the audio thread, so the storage is atomic and allocation
// free after creation.
#ifndef CMIX_STATS_H
#define CMIX_STATS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cmix_stats cmix_stats;

/// Snapshot of every counter, copied with relaxed atomic reads.
typedef struct {
    uint64_t underrun_frames;
    uint64_t overrun_frames;
    uint64_t frames_in;
    uint64_t frames_out;
    int64_t fill_frames;
} cmix_stats_snapshot;

cmix_stats *cmix_stats_create(void);
void cmix_stats_destroy(cmix_stats *stats);

void cmix_stats_add_underrun(cmix_stats *stats, uint64_t frames);
void cmix_stats_add_overrun(cmix_stats *stats, uint64_t frames);
void cmix_stats_add_frames(cmix_stats *stats, uint64_t input, uint64_t output);
void cmix_stats_set_fill(cmix_stats *stats, int64_t frames);
void cmix_stats_reset(cmix_stats *stats);

cmix_stats_snapshot cmix_stats_read(const cmix_stats *stats);

#ifdef __cplusplus
}
#endif

#endif /* CMIX_STATS_H */
