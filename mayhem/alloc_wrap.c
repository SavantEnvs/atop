/* Linked with -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc into the file-input tools. A raw-log
 * record header carries a length that atop passes to malloc() (rawlog.c getrawsstat() and friends).
 * A real libc returns NULL for an absurd size and atop's ptrverify() then exits cleanly; the ASan
 * allocator aborts instead, which makes the harness look worse than production and hides the code
 * behind it. Refuse sizes above LIMIT like an out-of-memory host does; everything else is passed
 * through to the real (ASan) allocator unchanged. */
#include <errno.h>
#include <stddef.h>

#define LIMIT ((size_t)256 << 20)

void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);

void *__wrap_malloc(size_t size)
{
	if (size > LIMIT) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_malloc(size);
}

void *__wrap_calloc(size_t n, size_t size)
{
	if (size && n > LIMIT / size) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_calloc(n, size);
}

void *__wrap_realloc(void *p, size_t size)
{
	if (size > LIMIT) {
		errno = ENOMEM;
		return NULL;
	}
	return __real_realloc(p, size);
}
