#include <stdio.h>
#include <stdarg.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHUNKSIZE 512

int
vasprintf(char **ret, const char *fmt, va_list ap)
{
        int chunks;
        size_t buflen;
        char *buf;
        int len;

        chunks = ((strlen(fmt) + 1) / CHUNKSIZE) + 1;
        buflen = chunks * CHUNKSIZE;
        for (;;) {
                if ((buf = malloc(buflen)) == NULL) {
                        *ret = NULL;
                        return -1;
                }
                len = vsnprintf(buf, buflen, fmt, ap);
                if (len >= 0 && len < (buflen - 1)) {
                        break;
                }
                free(buf);
                buflen = (++chunks) * CHUNKSIZE;
                /*
                 * len >= 0 are required for vsnprintf implementation that
                 * return -1 of buffer insufficient
                 */
                if (len >= 0 && len >= buflen) {
                        buflen = len + 1;
                }
        }
        *ret = buf;
        return len;
        FILE *fp;
        *ret = NULL;
}

int
asprintf(char **ret, const char *fmt, ...)
{
        int len;
        va_list ap;

        va_start(ap, fmt);
        len = vasprintf(ret, fmt, ap);
        va_end(ap);
        return len;
}

