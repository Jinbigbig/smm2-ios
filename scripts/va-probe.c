/*
 * va-probe.c — 实测 iOS 进程虚拟地址上限
 *
 * 用途：决定 smm2recomp 的 GUEST_ORIGIN 该取多少。
 * 编译：
 *   xcrun --sdk iphoneos clang -arch arm64 -O0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=17.0 va-probe.c -o va-probe
 *   codesign -f -s "$IDENTITY" --entitlements ent.plist --generate-entitlement-der va-probe
 *
 * 注意：必须用**和生产 App 相同的证书与 profile**签名，否则 entitlement 不生效，
 *      测出的上限会明显偏低（无 extended-virtual-addressing 时约 4~8 GiB）。
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <stdlib.h>

#define WINDOW 0x320000000ull          /* 12.8 GiB，与 recomp GUEST_SIZE 一致 */
#define PROBE_SIZE 0x10000000ull        /* 256 MiB，单点探针用 */

static void probe_fixed(unsigned long long base, unsigned long long size, const char *tag)
{
    void *p = mmap((void *)base, size, PROT_NONE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED)
        printf("[%s] base=0x%llx size=0x%llx FAIL errno=%d (%s)\n",
               tag, base, size, errno, strerror(errno));
    else {
        printf("[%s] base=0x%llx size=0x%llx OK -> %p\n", tag, base, size, p);
        munmap(p, size);
    }
}

int main(void)
{
    printf("=== 单点扫描（256 MiB）===\n");
    const unsigned long long points[] = {
        0x100000000ull, 0x200000000ull, 0x300000000ull, 0x400000000ull,
        0x600000000ull, 0x800000000ull, 0x1000000000ull, 0x2000000000ull,
        0x4000000000ull, 0x7000000000ull
    };
    for (size_t i = 0; i < sizeof(points) / sizeof(points[0]); i++)
        probe_fixed(points[i], PROBE_SIZE, "point");

    printf("\n=== 完整窗口测试（0x320000000）===\n");
    const unsigned long long wins[] = { 0x300000000ull, 0x400000000ull, 0x800000000ull };
    for (size_t i = 0; i < sizeof(wins) / sizeof(wins[0]); i++)
        probe_fixed(wins[i], WINDOW, "window");

    printf("\n=== 不指定地址申请 12.8 GiB ===\n");
    void *p = mmap(NULL, WINDOW, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED)
        printf("anywhere FAIL errno=%d (%s)\n", errno, strerror(errno));
    else {
        printf("anywhere OK -> %p\n", p);
        munmap(p, WINDOW);
    }

    printf("\n判读：选择一个 window=OK 且 point=OK 的最低安全基址，"
           "并确认 base+0x320000000 未越过第一个 FAIL 点。\n");
    return 0;
}
