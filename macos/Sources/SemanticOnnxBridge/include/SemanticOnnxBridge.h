#ifndef GUGUTALK_SEMANTIC_ONNX_BRIDGE_H
#define GUGUTALK_SEMANTIC_ONNX_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuGuSemanticSession GuGuSemanticSession;

GuGuSemanticSession *gugu_semantic_session_create(const char *model_path, char **error_message);
void gugu_semantic_session_destroy(GuGuSemanticSession *session);

int32_t gugu_semantic_score_masked_tokens(
    GuGuSemanticSession *session,
    const int64_t *input_ids,
    const int64_t *attention_mask,
    int64_t sequence_length,
    const int64_t *target_positions,
    const int64_t *target_token_ids,
    int64_t target_count,
    double *score,
    char **error_message
);

void gugu_semantic_error_free(char *error_message);

#ifdef __cplusplus
}
#endif

#endif
