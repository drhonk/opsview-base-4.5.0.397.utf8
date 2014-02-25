#ifndef SUN_LEN
#define SUN_LEN(ptr) ((size_t) (((struct sockaddr_un *) 0)->sun_path) + strlen ((ptr)->sun_path))
#endif

/* 
int vasprintf(char **ret, const char *fmt, va_list ap);
int asprintf(char **ret, const char *fmt, ...);
*/
