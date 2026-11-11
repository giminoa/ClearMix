#include "cmix_denoise.h"

#include <stdlib.h>
#include <string.h>

#include "rnnoise.h"

// RNNoise's own examples feed samples in the int16 range, and the model was
// trained on that scale. Everything else in ClearMix works in -1...1, so the
// conversion lives here instead of leaking into the Swift DSP stages.
static const float kInputScale = 32768.0f;
static const float kOutputScale = 1.0f / 32768.0f;

struct cmix_denoiser {
    DenoiseState *state;
    float scaled[CMIX_DENOISE_FRAME_SIZE];
};

cmix_denoiser *cmix_denoiser_create(void) {
    if (rnnoise_get_frame_size() != CMIX_DENOISE_FRAME_SIZE) {
        return NULL;
    }
    cmix_denoiser *denoiser = (cmix_denoiser *)calloc(1, sizeof(cmix_denoiser));
    if (denoiser == NULL) {
        return NULL;
    }
    denoiser->state = rnnoise_create(NULL);
    if (denoiser->state == NULL) {
        free(denoiser);
        return NULL;
    }
    return denoiser;
}

void cmix_denoiser_destroy(cmix_denoiser *denoiser) {
    if (denoiser == NULL) {
        return;
    }
    rnnoise_destroy(denoiser->state);
    free(denoiser);
}

size_t cmix_denoiser_frame_size(const cmix_denoiser *denoiser) {
    (void)denoiser;
    return (size_t)CMIX_DENOISE_FRAME_SIZE;
}

uint32_t cmix_denoiser_sample_rate(const cmix_denoiser *denoiser) {
    (void)denoiser;
    return (uint32_t)CMIX_DENOISE_SAMPLE_RATE;
}

float cmix_denoiser_process(cmix_denoiser *denoiser, float *frame) {
    if (denoiser == NULL || frame == NULL) {
        return 0.0f;
    }

    float *scaled = denoiser->scaled;
    for (size_t index = 0; index < (size_t)CMIX_DENOISE_FRAME_SIZE; index++) {
        scaled[index] = frame[index] * kInputScale;
    }

    const float voice = rnnoise_process_frame(denoiser->state, scaled, scaled);

    for (size_t index = 0; index < (size_t)CMIX_DENOISE_FRAME_SIZE; index++) {
        frame[index] = scaled[index] * kOutputScale;
    }
    return voice;
}
