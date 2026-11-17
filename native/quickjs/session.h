#include <stdint.h>
void *ForceSniffQuickJsSessionCreate(int64_t memory_limit_bytes);
char *ForceSniffQuickJsSessionEval(void *session, const char *source, int timeout_ms);
void ForceSniffQuickJsSessionDestroy(void *session);
void ForceSniffQuickJsFree(char *ptr);
char *ForceSniffQuickJsExecute(const char *source, int timeout_ms, int64_t memory_limit_bytes);
const char *ForceSniffQuickJsRuntimeManifestJSON(void);
