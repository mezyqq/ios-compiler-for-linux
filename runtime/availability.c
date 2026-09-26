// Замена кусочка compiler-rt для Darwin, которого нет в clang под Linux:
// нужен для @available / #available / if (@available(...)).
#include <stdint.h>

typedef struct { uint32_t platform; uint32_t version; } dyld_build_version_t;
extern _Bool _availability_version_check(uint32_t count, dyld_build_version_t versions[]);

int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
	dyld_build_version_t v = { platform, ((major & 0xffff) << 16) | ((minor & 0xff) << 8) | (subminor & 0xff) };
	return _availability_version_check(1, &v);
}

int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor) {
	return __isPlatformVersionAtLeast(2 /* PLATFORM_IOS */, major, minor, subminor);
}
