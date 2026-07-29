#include "SemanticOnnxBridge.h"

#include "onnxruntime_c_api.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

struct GuGuSemanticSession {
    const OrtApi *api;
    OrtEnv *environment;
    OrtSession *session;
    OrtMemoryInfo *memory_info;
};

static void set_error(char **destination, const char *message) {
    if (destination == NULL) return;
    const char *resolved = message == NULL ? "Unknown ONNX Runtime error" : message;
    size_t length = strlen(resolved);
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) {
        *destination = NULL;
        return;
    }
    memcpy(copy, resolved, length + 1);
    *destination = copy;
}

static int status_ok(const OrtApi *api, OrtStatus *status, char **error_message) {
    if (status == NULL) return 1;
    set_error(error_message, api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return 0;
}

GuGuSemanticSession *gugu_semantic_session_create(const char *model_path, char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    if (model_path == NULL || model_path[0] == '\0') {
        set_error(error_message, "Semantic model path is empty");
        return NULL;
    }

    const OrtApiBase *api_base = OrtGetApiBase();
    const OrtApi *api = api_base == NULL ? NULL : api_base->GetApi(ORT_API_VERSION);
    if (api == NULL) {
        set_error(error_message, "Compatible ONNX Runtime C API is unavailable");
        return NULL;
    }

    GuGuSemanticSession *result = (GuGuSemanticSession *)calloc(1, sizeof(GuGuSemanticSession));
    if (result == NULL) {
        set_error(error_message, "Unable to allocate semantic model session");
        return NULL;
    }
    result->api = api;

    OrtSessionOptions *options = NULL;
    if (!status_ok(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "GuGuTalkSemantic", &result->environment), error_message) ||
        !status_ok(api, api->CreateSessionOptions(&options), error_message) ||
        !status_ok(api, api->SetIntraOpNumThreads(options, 1), error_message) ||
        !status_ok(api, api->SetInterOpNumThreads(options, 1), error_message) ||
        !status_ok(api, api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), error_message) ||
        !status_ok(api, api->CreateSession(result->environment, model_path, options, &result->session), error_message) ||
        !status_ok(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &result->memory_info), error_message)) {
        if (options != NULL) api->ReleaseSessionOptions(options);
        gugu_semantic_session_destroy(result);
        return NULL;
    }

    api->ReleaseSessionOptions(options);
    return result;
}

void gugu_semantic_session_destroy(GuGuSemanticSession *session) {
    if (session == NULL) return;
    if (session->api != NULL) {
        if (session->memory_info != NULL) session->api->ReleaseMemoryInfo(session->memory_info);
        if (session->session != NULL) session->api->ReleaseSession(session->session);
        if (session->environment != NULL) session->api->ReleaseEnv(session->environment);
    }
    free(session);
}

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
) {
    if (error_message != NULL) *error_message = NULL;
    if (session == NULL || input_ids == NULL || attention_mask == NULL ||
        target_positions == NULL || target_token_ids == NULL || score == NULL ||
        sequence_length <= 0 || target_count <= 0) {
        set_error(error_message, "Invalid semantic scoring arguments");
        return 0;
    }

    const OrtApi *api = session->api;
    int64_t shape[2] = {1, sequence_length};
    OrtValue *input_id_tensor = NULL;
    OrtValue *attention_tensor = NULL;
    OrtValue *output = NULL;
    OrtTensorTypeAndShapeInfo *output_info = NULL;
    size_t byte_count = (size_t)sequence_length * sizeof(int64_t);

    if (!status_ok(api, api->CreateTensorWithDataAsOrtValue(
            session->memory_info, (void *)input_ids, byte_count, shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &input_id_tensor), error_message) ||
        !status_ok(api, api->CreateTensorWithDataAsOrtValue(
            session->memory_info, (void *)attention_mask, byte_count, shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &attention_tensor), error_message)) goto cleanup;

    const char *input_names[] = {"input_ids", "attention_mask"};
    const OrtValue *inputs[] = {input_id_tensor, attention_tensor};
    const char *output_names[] = {"logits"};
    if (!status_ok(api, api->Run(session->session, NULL, input_names, inputs, 2,
                                  output_names, 1, &output), error_message)) goto cleanup;
    if (!status_ok(api, api->GetTensorTypeAndShape(output, &output_info), error_message)) goto cleanup;

    size_t dimension_count = 0;
    if (!status_ok(api, api->GetDimensionsCount(output_info, &dimension_count), error_message)) goto cleanup;
    if (dimension_count != 3) {
        set_error(error_message, "Semantic model logits must have three dimensions");
        goto cleanup;
    }

    int64_t dimensions[3] = {0, 0, 0};
    if (!status_ok(api, api->GetDimensions(output_info, dimensions, 3), error_message)) goto cleanup;
    if (dimensions[0] != 1 || dimensions[1] != sequence_length || dimensions[2] <= 0) {
        set_error(error_message, "Semantic model returned an unexpected logits shape");
        goto cleanup;
    }

    float *logits = NULL;
    if (!status_ok(api, api->GetTensorMutableData(output, (void **)&logits), error_message)) goto cleanup;

    const int64_t vocabulary_size = dimensions[2];
    double total = 0.0;
    for (int64_t target_index = 0; target_index < target_count; target_index++) {
        int64_t position = target_positions[target_index];
        int64_t token_id = target_token_ids[target_index];
        if (position < 0 || position >= sequence_length || token_id < 0 || token_id >= vocabulary_size) {
            set_error(error_message, "Semantic target token is outside the logits tensor");
            goto cleanup;
        }

        const float *row = logits + position * vocabulary_size;
        float maximum = row[0];
        for (int64_t index = 1; index < vocabulary_size; index++) {
            if (row[index] > maximum) maximum = row[index];
        }

        double exponential_sum = 0.0;
        for (int64_t index = 0; index < vocabulary_size; index++) {
            exponential_sum += exp((double)row[index] - (double)maximum);
        }
        total += (double)row[token_id] - (double)maximum - log(exponential_sum);
    }

    *score = total / (double)target_count;
    if (output_info != NULL) api->ReleaseTensorTypeAndShapeInfo(output_info);
    if (output != NULL) api->ReleaseValue(output);
    if (attention_tensor != NULL) api->ReleaseValue(attention_tensor);
    if (input_id_tensor != NULL) api->ReleaseValue(input_id_tensor);
    return 1;

cleanup:
    if (output_info != NULL) api->ReleaseTensorTypeAndShapeInfo(output_info);
    if (output != NULL) api->ReleaseValue(output);
    if (attention_tensor != NULL) api->ReleaseValue(attention_tensor);
    if (input_id_tensor != NULL) api->ReleaseValue(input_id_tensor);
    return 0;
}

void gugu_semantic_error_free(char *error_message) {
    free(error_message);
}
