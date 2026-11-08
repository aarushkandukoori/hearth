// PieServerCore for the iOS Simulator: every call says Pie is not here.
// Pie's Metal engine runs on a real iPhone; Simulator builds (unit tests, UI
// checks) link this stub so the app still builds and falls back to demo
// replies.
#include <stdlib.h>
#include <string.h>
#include "pie.h"

static pie_status unavailable(char **error) {
    if (error) *error = strdup("Pie runs on a real iPhone, not in the Simulator.");
    return PIE_ERR_FAILED;
}

const char *pie_version(void) { return PIE_VERSION_STRING; }
pie_status pie_server_start(const char *artifact, const char *config, const char *home,
                            const char *listen, pie_server **out, char **error) {
    (void)artifact; (void)config; (void)home; (void)listen;
    if (out) *out = NULL;
    return unavailable(error);
}
const char *pie_server_summary(const pie_server *server) { (void)server; return "{}"; }
const char *pie_server_listen_addr(const pie_server *server) { (void)server; return NULL; }
pie_status pie_server_install(pie_server *server, const uint8_t *bytes, size_t len,
                              const char *file, const char *version, char **name, char **error) {
    (void)server; (void)bytes; (void)len; (void)file; (void)version;
    if (name) *name = NULL;
    return unavailable(error);
}
pie_status pie_server_install_language(pie_server *server, const char *language,
                                       const uint8_t *bytes, size_t len, char **error) {
    (void)server; (void)language; (void)bytes; (void)len;
    return unavailable(error);
}
pie_status pie_server_open_session(pie_server *server, uint32_t *session, char **error) {
    (void)server; (void)session;
    return unavailable(error);
}
void pie_server_close_session(pie_server *server, uint32_t session) { (void)server; (void)session; }
pie_status pie_server_send_frame(pie_server *server, uint32_t session, const uint8_t *frame,
                                 size_t len, char **error) {
    (void)server; (void)session; (void)frame; (void)len;
    return unavailable(error);
}
pie_status pie_server_recv_frames(pie_server *server, uint32_t session, uint32_t max_wait_ms,
                                  size_t max_frames, pie_frame_fn on_frame, void *ctx,
                                  size_t *received, char **error) {
    (void)server; (void)session; (void)max_wait_ms; (void)max_frames; (void)on_frame; (void)ctx;
    if (received) *received = 0;
    return PIE_ERR_SHUT_DOWN;
    (void)error;
}
void pie_server_shutdown(pie_server *server) { (void)server; }
void pie_server_free(pie_server *server) { (void)server; }
void pie_string_free(char *s) { free(s); }
