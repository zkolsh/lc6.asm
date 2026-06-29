#include "elf_io.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

void vram_to_s_cmd(const uint8_t* desc_mem, const size_t size) {
	printf("Hex View  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F\n");

	for (size_t i = 0; i < size; i += 16) {
		printf("%08X  ", (unsigned int)i);

		for (size_t j = 0; j < 16; j++) {
			if (i + j < size) {
				printf("%02X ", desc_mem[i + j]);
			} else {
				printf("   ");
			};

			if (j == 7) {
				printf(" ");
			};
		};

		printf(" ");

		for (size_t j = 0; j < 16; j++) {
			if (i + j >= size) {
				continue;
			};
			uint8_t ch = desc_mem[i + j];
			if (ch >= 32 && ch <= 126) {
				printf("%c", ch);
			} else {
				printf(".");
			};
		};

		printf("\n");
	};

	printf("\n");
};

static uint8_t* map_file(const char* filepath, size_t* out_size) {
	int fd = open(filepath, O_RDONLY);
	if (fd < 0) {
		perror("failed to open file");
		return NULL;
	};

	struct stat st;
	if (fstat(fd, &st) < 0) {
		perror("failed to stat file");
		close(fd);
		return NULL;
	};

	*out_size = st.st_size;
	uint8_t* map = mmap(NULL, *out_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	close(fd);

	if (map == MAP_FAILED) {
		perror("mmap failed :(");
		return NULL;
	};

	return map;
};

int main(int argc, char** argv) {
	if (argc != 2 && argc != 3) {
		fprintf(stderr, "usage:  %s <ELF program> OR %s <os.elf> <mem.elf>\n", argv[0], argv[0]);
		return EXIT_FAILURE;
	};

	ElfView elves[2] = {0};
	size_t file_sizes[2] = {0};
	uint8_t* file_buffers[2] = {NULL, NULL};
	size_t views = 0;

	if (argc == 2) {
		file_buffers[0] = map_file(argv[1], &file_sizes[0]);

		if (!file_buffers[0]) {
			return EXIT_FAILURE;
		};

		views = 1;
	} else {
		file_buffers[0] = map_file(argv[1], &file_sizes[0]);
		file_buffers[1] = map_file(argv[2], &file_sizes[1]);

		if (!file_buffers[0] || !file_buffers[1]) {
			return EXIT_FAILURE;
		};

		views = 2;
	};

	for (size_t i = 0; i < views; i++) {
		ElfStatus status = elf_view_parse(&elves[i], file_sizes[i], file_buffers[i]);

		if (status != ELF_SUCCESS) {
			fprintf(stderr, "error parsing file %s: %d\n", argv[i + 1], status);
			return EXIT_FAILURE;
		};
	};

	ElfLayoutMap layout = {0};
	ElfStatus status = elf_merge_calculate_layout(&layout, elves, views);
	if (status != ELF_SUCCESS) {
		fprintf(stderr, "cannot compute layout specification: %d\n", status);
		return EXIT_FAILURE;
	};

	uint8_t* ram = calloc(1, layout.total_memory_needed);
	if (!ram) {
		fprintf(stderr, "out of host memory allocation space\n");
		return EXIT_FAILURE;
	};

	const uint32_t text_vaddr = (0 + (layout.text_align - 1)) & ~(layout.text_align - 1);
	const uint32_t data_vaddr = (text_vaddr + layout.text_size + (layout.data_align - 1)) & ~(layout.data_align - 1);

	status = elf_merge(ram, layout.total_memory_needed, &layout, elves, views);
	if (status != ELF_SUCCESS) {
		fprintf(stderr, "unable to merge views into segment space: %d\n", status);
		free(ram);
		return EXIT_FAILURE;
	};

	for (size_t i = 0; i < views; i++) {
		if (elves[i].header->e_type != ET_REL) {
			continue;
		};

		elf_view_patch_relocations(&elves[i], ram, layout.total_memory_needed, ".text", text_vaddr, data_vaddr);
		elf_view_patch_relocations(&elves[i], ram, layout.total_memory_needed, ".data", text_vaddr, data_vaddr);
	};

	vram_to_s_cmd(ram, layout.total_memory_needed);

	const uint32_t text_end = text_vaddr + layout.text_size;
	const uint32_t data_end = data_vaddr + layout.data_size;

	uint32_t global_entry = elves[0].header->e_entry;
	if (elves[0].header->e_type == ET_REL) {
		global_entry += text_vaddr;
	};

	printf(".text segment mapping:  0x%08X -> 0x%08X (%zu bytes)\n", text_vaddr, text_end, layout.text_size);
	printf(".data segment mapping:  0x%08X -> 0x%08X (%zu bytes)\n", data_vaddr, data_end, layout.data_size);
	printf("entry point is 0x%08X\n", global_entry);

	free(ram);
	for (size_t i = 0; i < views; i++) {
		munmap(file_buffers[i], file_sizes[i]);
	};

	return EXIT_SUCCESS;
};
