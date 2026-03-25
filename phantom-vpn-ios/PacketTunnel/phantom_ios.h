#ifndef PHANTOM_IOS_H
#define PHANTOM_IOS_H

#include <stdint.h>

typedef int32_t (*phantom_protect_cb_t)(int32_t fd);

int32_t phantom_start(int32_t tun_fd, const char* config_json);
void phantom_stop(void);
char* phantom_get_stats(void);
char* phantom_get_logs(int64_t since_seq);
void phantom_set_log_level(const char* level);
char* phantom_compute_vpn_routes(const char* direct_cidrs);
void phantom_free_string(char* ptr);
void phantom_set_protect_callback(phantom_protect_cb_t cb);

#endif
