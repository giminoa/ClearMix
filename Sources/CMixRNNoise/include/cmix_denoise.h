// ClearMix noise-suppression shim.
//
// RNNoise is a C library that expects 16-bit-scaled float samples in fixed
// 480-sample blocks. This shim keeps that detail on the C side so the Swift
// side works in the same -1...1 range as the rest of the DSP chain.
//
// Like the ring buffer, everything here is allocation-free after
// `cmix_denoiser_create`: the render callback may call `cmix_denoiser_process`
// but must never call create/destroy from it.
#ifndef CMIX_DENOISE_H
#define CMIX_DENOISE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Samples per RNNoise block: 10 ms at 48 kHz.
#define CMIX_DENOISE_FRAME_SIZE 480
/// RNNoise only runs at 48 kHz.
#define CMIX_DENOISE_SAMPLE_RATE 48000

typedef struct cmix_denoiser cmix_denoiser;

/// Allocates a denoiser with a fresh recurrent state. Returns NULL on failure.
cmix_denoiser *cmix_denoiser_create(void);
void cmix_denoiser_destroy(cmix_denoiser *denoiser);

/// Block size the shim actually uses (validated against the library at create).
size_t cmix_denoiser_frame_size(const cmix_denoiser *denoiser);
/// Sample rate the shim actually runs at.
uint32_t cmix_denoiser_sample_rate(const cmix_denoiser *denoiser);

/// Denoises exactly `cmix_denoiser_frame_size` mono samples in place.
///
/// `frame` holds normalised samples (-1...1) and keeps that range on return.
/// Returns RNNoise's voice-activity probability for the block (0...1), which
/// the mic chain uses to decide whether to let the block through.
float cmix_denoiser_process(cmix_denoiser *denoiser, float *frame);

#ifdef __cplusplus
}
#endif

#endif /* CMIX_DENOISE_H */
