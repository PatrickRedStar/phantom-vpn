#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void (*phantom_callback_t)(const uint8_t *, intptr_t, void *);

int32_t phantom_runtime_start(
    const char *cfg_json,
    const char *settings_json,
    phantom_callback_t status_cb,
    phantom_callback_t log_cb,
    phantom_callback_t outbound_cb,
    void *ctx
) {
    (void)cfg_json;
    (void)settings_json;
    (void)status_cb;
    (void)log_cb;
    (void)outbound_cb;
    (void)ctx;
    return -1;
}

int32_t phantom_runtime_submit_inbound(const uint8_t *buf, intptr_t len) {
    (void)buf;
    (void)len;
    return -1;
}

int32_t phantom_runtime_stop(void) {
    return 0;
}

char *phantom_parse_conn_string(const char *input) {
    (void)input;
    return NULL;
}

char *phantom_compute_vpn_routes(const char *cidrs) {
    (void)cidrs;
    char *out = malloc(3);
    if (out == NULL) {
        return NULL;
    }
    memcpy(out, "[]", 3);
    return out;
}

void phantom_free_string(char *ptr) {
    free(ptr);
}
