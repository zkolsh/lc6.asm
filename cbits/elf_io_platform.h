#ifndef ELFIO_PLATFORM_H
#define ELFIO_PLATFORM_H

#if !defined(ELFIO_AVOID_LIBC)
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#else
typedef unsigned char  uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int   uint32_t;
typedef signed int     int32_t;
typedef __SIZE_TYPE__  size_t;

#define SIZE_MAX ((size_t)-1)
#define NULL ((void *)0)

extern void* elfio_memset(void* s, int c, size_t n);
extern void* elfio_memcpy(void* dest, const void* src, size_t n);
extern size_t elfio_strlen(const char* s); 
extern int elfio_strcmp(const char* s1, const char* s2);
extern int elfio_strncmp(const char* s1, const char* s2, size_t n);
extern char* elfio_strcat(char* dest, const char* src);
extern char* elfio_strncat(char* dest, const char* src, size_t n);
extern char* elfio_strncpy(char* dest, const char* src, size_t n);

#define memset  elfio_memset
#define memcpy  elfio_memcpy
#define strlen  elfio_strlen
#define strcmp  elfio_strcmp
#define strncmp elfio_strncmp
#define strcat  elfio_strcat
#define strncat elfio_strncat
#define strncpy elfio_strncpy
#endif /* ELFIO_AVOID_LIBC */

#endif /* ELFIO_PLATFORM_H */
