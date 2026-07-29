#include "elf_io.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#if !defined(AS_TELNET_CMDS)
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
#else
void vram_to_s_cmd(const uint8_t* desc_mem, const size_t size) {
	for (size_t i = 0; i < size; i += 4) {
		const uint32_t word = ((i + 0 < size) ? ((uint32_t)desc_mem[i + 0] <<  0) : 0)
		                    | ((i + 1 < size) ? ((uint32_t)desc_mem[i + 1] <<  8) : 0)
		                    | ((i + 2 < size) ? ((uint32_t)desc_mem[i + 2] << 16) : 0)
		                    | ((i + 3 < size) ? ((uint32_t)desc_mem[i + 3] << 24) : 0);
		if (word == 0) continue;
		printf("s [0x%08X] 0x%08X\n", (uint32_t)i, word);
	};
};
#endif

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

	status = elf_merge(ram, layout.total_memory_needed, &layout, elves, views);
	if (status != ELF_SUCCESS) {
		fprintf(stderr, "unable to merge views into segment space: %d\n", status);
		free(ram);
		return EXIT_FAILURE;
	};

	ElfSectionAddress section_addresses[ELFIO_MAX_LAYOUT_SECTIONS];
	for (size_t i = 0; i < layout.section_count; i++) {
		section_addresses[i].section_name = layout.sections[i].name;
		section_addresses[i].base_vaddr = (uint32_t)layout.sections[i].base_vaddr;
	};

	for (size_t i = 0; i < views; i++) {
		if (elves[i].header->e_type != ET_REL) {
			continue;
		};

		for (size_t s = 0; s < layout.section_count; s++) {
			const char* sec_name = layout.sections[s].name;
			uint32_t base_vaddr = (uint32_t)layout.sections[s].base_vaddr;
			uint32_t size = (uint32_t)layout.sections[s].size;

			if (size == 0) continue;

			status = elf_view_patch_relocations(&elves[i], ram + base_vaddr,
				size, sec_name, section_addresses, layout.section_count);

			if (status != ELF_SUCCESS) {
				fprintf(stderr, "failed to patch relocations for section %s: %s (%d)\n", 
					sec_name, elf_status_str(status), status);
				free(ram);
				return EXIT_FAILURE;
			};
		};
	};

	vram_to_s_cmd(ram, layout.total_memory_needed);

#if !defined(AS_TELNET_CMDS)
	for (size_t i = 0; i < layout.section_count; i++) {
		uint32_t vaddr = (uint32_t)layout.sections[i].base_vaddr;
		uint32_t end_vaddr = vaddr + (uint32_t)layout.sections[i].size;
		printf("%s segment mapping:  0x%08X -> 0x%08X (%zu bytes)\n", 
			layout.sections[i].name, vaddr, end_vaddr, layout.sections[i].size);
	};
#endif

	uint32_t global_entry = elves[0].header->e_entry;
	if (elves[0].header->e_type == ET_REL) {
		for (size_t i = 0; i < layout.section_count; i++) {
			if (strcmp(layout.sections[i].name, ".text") == 0) {
				global_entry += (uint32_t)layout.sections[i].base_vaddr;
				break;
			};
		};
	};

#if !defined(AS_TELNET_CMDS)
	printf("entry point is 0x%08X\n", global_entry);
#else
	printf("s PC 0x%08X\n", global_entry);
#endif

	free(ram);
	for (size_t i = 0; i < views; i++) {
		munmap(file_buffers[i], file_sizes[i]);
	};

	return EXIT_SUCCESS;
};
