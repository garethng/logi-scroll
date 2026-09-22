// hid_bridge — logi_scroll 用到的 hidapi 最小 C 接口（供 Swift 通过 @_silgen_name 调用）
#ifndef LOGI_HID_BRIDGE_H
#define LOGI_HID_BRIDGE_H

#include <stddef.h>

// 打开路径（"DevSrvsID:<registry id>"），失败返回 NULL
void *logi_hid_open(const char *path);
// 写报告（data[0] 为报告 ID），返回写入字节数，失败返回 -1
int logi_hid_write(void *h, const unsigned char *data, size_t len);
// 读输入报告，最多等 ms 毫秒；返回长度，超时返回 0，失败返回 -1
int logi_hid_read_timeout(void *h, unsigned char *data, size_t len, int ms);
void logi_hid_close(void *h);

#endif
