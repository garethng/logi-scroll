// hid_bridge — logi_scroll 用到的 hidapi 最小 C 接口
#include "hid_bridge.h"
#include "vendor/hidapi.h"

void *logi_hid_open(const char *path) {
    return hid_open_path(path);
}

int logi_hid_write(void *h, const unsigned char *data, size_t len) {
    return hid_write((hid_device *)h, data, len);
}

int logi_hid_read_timeout(void *h, unsigned char *data, size_t len, int ms) {
    return hid_read_timeout((hid_device *)h, data, len, ms);
}

void logi_hid_close(void *h) {
    hid_close((hid_device *)h);
}

// 全局错误信息（h 传 NULL 时返回最近一次 open 失败的原因）
const wchar_t *logi_hid_error(void *h) {
    return hid_error((hid_device *)h);
}
