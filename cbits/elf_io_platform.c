#include "elf_io_platform.h"

void* elfio_memset(void* s, int c, size_t n) {
	unsigned char* p = (unsigned char*)s;
	while (n--) {
		*p++ = (unsigned char)c;
	};

	return s;
};

void* elfio_memcpy(void* dest, const void* src, size_t n) {
	unsigned char* d = (unsigned char*)dest;
	const unsigned char* s = (const unsigned char*)src;
	while (n--) {
		*d++ = *s++;
	};

	return dest;
};

size_t elfio_strlen(const char* s) {
	const char* p = s;
	while (*p) {
		p++;
	};
	return (size_t)(p - s);
};

int elfio_strcmp(const char* s1, const char* s2) {
	while (*s1 && (*s1 == *s2)) {
		s1++;
		s2++;
	};
	return *(const unsigned char*)s1 - *(const unsigned char*)s2;
};

int elfio_strncmp(const char* s1, const char* s2, size_t n) {
	if (n == 0) return 0;
	while (n > 0 && *s1 && (*s1 == *s2)) {
		s1++;
		s2++;
	};
	return *(const unsigned char*)s1 - *(const unsigned char*)s2;
};

char* elfio_strcat(char* dest, const char* src) {
	char* d = dest;
	while (*d) {
		d++;
	};
	while ((*d++ = *src++));
	return dest;
};

char* elfio_strncat(char* dest, const char* src, size_t n) {
	char* d = dest;
	while (*d) {
		d++;
	}
	
	size_t i = 0;
	while (i < n && src[i] != '\0') {
		d[i] = src[i];
		i++;
	}
	d[i] = '\0';

	return dest;
};

char* elfio_strncpy(char* dest, const char* src, size_t n) {
	char* d = dest;
	while (n > 0 && *src != '\0') {
		*d++ = *src++;
		n--;
	};

	while (n > 0) {
		*d++ = '\0';
		n--;
	};

	return dest;
};
