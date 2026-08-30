#include "elf_io.h" // references defined here

#include <string.h>

#if defined(DEBUG)
#include <stdio.h>
#endif

const char* elf_status_str(const ElfStatus status) {
	switch (status) {
	case ELF_SUCCESS:
		return "ELF_SUCCESS";
	case ELF_ARCH_MISMATCH:
		return "ELF_ARCH_MISMATCH";
	case ELF_BUFFER_TOO_SMALL:
		return "ELF_BUFFER_TOO_SMALL";
	case ELF_ENDIANNESS_MISMATCH:
		return "ELF_ENDIANNESS_MISMATCH";
	case ELF_INVALID_EHDR:
		return "ELF_INVALID_EHDR";
	case ELF_INVALID_MAGIC:
		return "ELF_INVALID_MAGIC";
	case ELF_MISSING_PARAMS:
		return "ELF_MISSING_PARAMS";
	case ELF_WORDSIZE_MISMATCH:
		return "ELF_WORDSIZE_MISMATCH";
	case ELF_SYMBOL_NOT_FOUND:
		return "ELF_SYMBOL_NOT_FOUND";
	case ELF_SYMBOL_TABLE_NOT_FOUND:
		return "ELF_SYMBOL_TABLE_NOT_FOUND";
	case ELF_INVALID_RELOCATION:
		return "ELF_INVALID_RELOCATION";
	default:
		return "invalid ElfStatus";
	};
};

const char* elf_type_str(const ElfType type) {
	switch (type) {
	case ET_NONE:
		return "ET_NONE";
	case ET_REL:
		return "ET_REL";
	case ET_EXEC:
		return "ET_EXEC";
	case ET_DYN:
		return "ET_DYN";
	case ET_CORE:
		return "ET_CORE";
	case ET_LOPROC:
		return "ET_LOPROC";
	case ET_HIPROC:
		return "ET_HIPROC";
	default:
		return "invalid ElfType";
	};
};

const char* elf_sh_type_str(const ElfShType type) {
	switch (type) {
	case SHT_NULL:
		return "SHT_NULL";
	case SHT_PROGBITS:
		return "SHT_PROGBITS";
	case SHT_SYMTAB:
		return "SHT_SYMTAB";
	case SHT_STRTAB:
		return "SHT_STRTAB";
	case SHT_RELA:
		return "SHT_RELA";
	case SHT_NOBITS:
		return "SHT_NOBITS";
	case SHT_REL:
		return "SHT_REL";
	default:
		return "invalid ElfShType";
	};
};

size_t elf_writer_calculate_size(const ElfRawSection* sections, size_t count) {
	if (!sections || count == 0) return 0;
	size_t current_offset = sizeof(ElfEHDR);

	for (size_t i = 0; i < count; i++) {
		uint32_t align = sections[i].addralign ? sections[i].addralign : 1;
		current_offset = (current_offset + (align - 1)) & ~(align - 1);

		if (sections[i].type != SHT_NOBITS) {
			current_offset += sections[i].size;
		};
	};

	size_t shstrtab_size = 1 + 10;
	for (size_t i = 0; i < count; i++) {
		shstrtab_size += 1 + strlen(sections[i].name);
	};

	current_offset = (current_offset + 3) & ~3;
	current_offset += shstrtab_size;

	const size_t total_section_headers = count + 2;
	current_offset = (current_offset + 3) & ~3;
	current_offset += (total_section_headers * sizeof(ElfSHDR));

	return current_offset;
};

ElfStatus elf_writer_serialize(
		uint8_t* dest_buffer, size_t dest_capacity,
		ElfType out_type, uint32_t entry_point,
		const ElfRawSection* sections, size_t count) {
	if (!dest_buffer || !sections || count == 0) return ELF_MISSING_PARAMS;

	const size_t required_size = elf_writer_calculate_size(sections, count);
	if (dest_capacity < required_size) return ELF_BUFFER_TOO_SMALL;

	for (size_t i = 0; i < dest_capacity; i++) dest_buffer[i] = 0;
	memset(dest_buffer, 0, dest_capacity);

	size_t current_payload_offset = sizeof(ElfEHDR);
	uint32_t file_offsets[32] = {0}; 
	if (count > 32) return ELF_BUFFER_TOO_SMALL;

	for (size_t i = 0; i < count; i++) {
		uint32_t align = sections[i].addralign ? sections[i].addralign : 1;
		current_payload_offset = (current_payload_offset + (align - 1)) & ~(align - 1);

		if (sections[i].type == SHT_NOBITS) {
			file_offsets[i] = 0;
		} else {
			file_offsets[i] = (uint32_t)current_payload_offset;
			memcpy(&dest_buffer[current_payload_offset], sections[i].data, sections[i].size);
			current_payload_offset += sections[i].size;
		};
	};

	current_payload_offset = (current_payload_offset + 3) & ~3;
	const uint32_t shstrtab_file_offset = (uint32_t)current_payload_offset;

	uint8_t* str_ptr = &dest_buffer[shstrtab_file_offset];
	*str_ptr++ = '\0';

	uint32_t string_indices[32] = {0};
	for (size_t i = 0; i < count; i++) {
		string_indices[i] = (uint32_t)(str_ptr - &dest_buffer[shstrtab_file_offset]);
		size_t len = strlen(sections[i].name);
		memcpy(str_ptr, sections[i].name, len + 1);
		str_ptr += len + 1;
	};

	const uint32_t shstrtab_name_index = (uint32_t)(str_ptr - &dest_buffer[shstrtab_file_offset]);
	const char* shstr_name = ".shstrtab";
	strcat((char*)str_ptr, shstr_name);
	str_ptr += 1 + strlen(shstr_name);

	current_payload_offset = (size_t)(str_ptr - dest_buffer);
	current_payload_offset = (current_payload_offset + 3) & ~3;

	const uint32_t sh_table_offset = (uint32_t)current_payload_offset;
	ElfSHDR* shdr_array = (ElfSHDR*)&dest_buffer[sh_table_offset];

	shdr_array[0] = (ElfSHDR){0};
	for (size_t i = 0; i < count; i++) {
		shdr_array[i + 1] = (ElfSHDR){
			.sh_name      = string_indices[i],
			.sh_type      = sections[i].type,
			.sh_flags     = sections[i].flags,
			.sh_addr      = sections[i].vaddr,
			.sh_offset    = file_offsets[i],
			.sh_size      = sections[i].size,
			.sh_link      = sections[i].link,
			.sh_info      = sections[i].info,
			.sh_addralign = sections[i].addralign,
			.sh_entsize   = sections[i].entsize,
		};
	};

	uint32_t shstrtab_size = (uint32_t)((str_ptr - dest_buffer) - shstrtab_file_offset);
	uint32_t shstrtab_index = (uint32_t)(count + 1);
	shdr_array[shstrtab_index] = (ElfSHDR){
		.sh_name      = shstrtab_name_index,
		.sh_type      = SHT_STRTAB,
		.sh_flags     = SHF_NONE,
		.sh_addr      = 0,
		.sh_offset    = shstrtab_file_offset,
		.sh_size      = shstrtab_size,
		.sh_link      = 0,
		.sh_info      = 0,
		.sh_addralign = 1,
		.sh_entsize   = 0
	};

	ElfEHDR* ehdr = (ElfEHDR*)dest_buffer;
	ehdr->e_ident[0]  = 0x7F; ehdr->e_ident[1] = 'E'; ehdr->e_ident[2] = 'L'; ehdr->e_ident[3] = 'F';
	ehdr->e_ident[4]  = 1;
	ehdr->e_ident[5]  = 1;
	ehdr->e_ident[6]  = EV_CURRENT;
	ehdr->e_type      = out_type;
	ehdr->e_machine   = EMACHINE_RTM32;
	ehdr->e_version   = EV_CURRENT;
	ehdr->e_entry     = entry_point;
	ehdr->e_phoff     = 0;
	ehdr->e_shoff     = sh_table_offset;
	ehdr->e_flags     = 0;
	ehdr->e_ehsize    = sizeof(ElfEHDR);
	ehdr->e_phentsize = 0;
	ehdr->e_phnum     = 0;
	ehdr->e_shentsize = sizeof(ElfSHDR);
	ehdr->e_shnum     = (uint16_t)(count + 2);
	ehdr->e_shstrndx  = (uint16_t)shstrtab_index;

	return ELF_SUCCESS;
};

ElfStatus elf_view_parse(ElfView* output, const size_t size, const uint8_t* buffer) {
	if (output == NULL) return ELF_MISSING_PARAMS;
	if (size < sizeof(ElfEHDR)) return ELF_BUFFER_TOO_SMALL;

	const ElfEHDR* ehdr = (ElfEHDR*)buffer;

	// source:  [1] chapter 1, page 20, "ELF identification"
	if (ehdr->e_ident[0] != 0x7F || ehdr->e_ident[1] != 'E'
	 || ehdr->e_ident[2] !=  'L' || ehdr->e_ident[3] != 'F') {
		return ELF_INVALID_MAGIC;
	};

	if (ehdr->e_ident[4] != 1) {
		return ELF_WORDSIZE_MISMATCH;
	};

	//NOTE:  zig fixes this
	if (ehdr->e_ident[5] != 1) {
		return ELF_ENDIANNESS_MISMATCH;
	};

	if (ehdr->e_ident[6] != 1) {
		return ELF_INVALID_EHDR;
	};

	if (ehdr->e_machine != EMACHINE_RTM32) {
		return ELF_ARCH_MISMATCH;
	};

	// if (ehdr->e_shstrndx >= ehdr->e_shnum) {
	// 	return ELF_INVALID_EHDR;
	// };

	/* Validation OK */
	output->buffer_view = buffer;
	output->buffer_size = size;
	output->header = ehdr;
	output->section_headers = (const ElfSHDR*)(buffer + ehdr->e_shoff);
	output->section_count = ehdr->e_shnum;
	output->shstrtab = (const char*)(buffer + output->section_headers[ehdr->e_shstrndx].sh_offset);

	if (ehdr->e_shstrndx < ehdr->e_shnum) {
		const ElfSHDR* shstrtab_shdr = &output->section_headers[ehdr->e_shstrndx];
		output->shstrtab = (const char*)(buffer + shstrtab_shdr->sh_offset);
	} else {
		output->shstrtab = NULL;
	};

	return ELF_SUCCESS;
};

ElfStatus elf_view_peek_symbol_value(const ElfView* view, const char* name, uint32_t* out_value) {
	if (!view || !name || !out_value) {
		return ELF_MISSING_PARAMS;
	};

	const ElfSHDR* symtab_shdr = elf_view_get_section_header(view, ".symtab");
	if (!symtab_shdr || symtab_shdr->sh_type != SHT_SYMTAB) {
		return ELF_SYMBOL_TABLE_NOT_FOUND;
	};

	if (symtab_shdr->sh_link >= view->section_count) {
		return ELF_INVALID_EHDR;
	};

	const ElfSHDR* strtab_shdr = &view->section_headers[symtab_shdr->sh_link];
	const char* strtab = (const char*)(view->buffer_view + strtab_shdr->sh_offset);

	const ElfSym* syms = (const ElfSym*)(view->buffer_view + symtab_shdr->sh_offset);
	size_t num_syms = symtab_shdr->sh_size / sizeof(ElfSym);

	// index 0 in the section headers is always garbage ([1], page 23)
	for (size_t i = 1; i < num_syms; i++) {
		const ElfSym* sym = &syms[i];
		const char* sym_name = strtab + sym->st_name;

		if (strcmp(sym_name, name) == 0) {
			*out_value = sym->st_value;
			return ELF_SUCCESS;
		};
	};

	return ELF_SYMBOL_NOT_FOUND;
};

const ElfSHDR* elf_view_get_section_header(const ElfView* view, const char* name) {
	if (!view || !view->section_headers || !view->shstrtab || !name) {
		return NULL;
	};

	// index 0 in the section headers is always garbage ([1], page 23)
	for (size_t i = 1; i < view->section_count; i++) {
		const ElfSHDR* shdr = &view->section_headers[i];
		const char* sec_name = view->shstrtab + shdr->sh_name;

		if (strcmp(sec_name, name) == 0) {
			return shdr;
		};
	};

	return NULL;
};

const uint8_t* elf_view_get_section(const ElfView* view, const char* name, uint32_t* out_size, uint32_t* out_flags) {
	const ElfSHDR* shdr = elf_view_get_section_header(view, name);
	if (!shdr) {
		if (out_size) {
			*out_size = 0;
		};

		if (out_flags) {
			*out_flags = 0;
		};

		return NULL;
	};

	if (out_size) {
		*out_size = shdr->sh_size;
	};

	if (out_flags) {
		*out_flags = shdr->sh_flags;
	};

	// sections with SHT_NOBITS occupy no space in the file ([1], page 25)
	if (shdr->sh_type == SHT_NOBITS) {
		return NULL; 
	};

	return view->buffer_view + shdr->sh_offset;
};

ElfStatus elf_view_patch_relocations(
		const ElfView* view, uint8_t* section_data, size_t section_data_size,
		const char* section_name, const ElfSectionAddress* layout, size_t layout_count) {
	if (!view || !section_data) return ELF_MISSING_PARAMS;

	const ElfSHDR* symtab_shdr = elf_view_get_section_header(view, ".symtab");
	if (!symtab_shdr) return ELF_INVALID_EHDR;
	const ElfSym* symtab = (const ElfSym*)(view->buffer_view + symtab_shdr->sh_offset);

	uint32_t current_sec_vaddr = 0;
	uint8_t current_vaddr_found = 0;
	for (size_t j = 0; j < layout_count; j++) {
		if (strcmp(layout[j].section_name, section_name) == 0) {
			current_sec_vaddr = layout[j].base_vaddr;
			current_vaddr_found = 1;
			break;
		};
	};

	const char* strtab = NULL;
	if (symtab_shdr->sh_link < view->section_count) {
		const ElfSHDR* strtab_shdr = &view->section_headers[symtab_shdr->sh_link];
		strtab = (const char*)(view->buffer_view + strtab_shdr->sh_offset);
	};

	char relsection_name[40] = ".rel";
	strncat(relsection_name, section_name, sizeof(relsection_name) - strlen(relsection_name) - 1);

	uint32_t rel_size = 0;
	const uint8_t* rel_bytes = elf_view_get_section(view, relsection_name, &rel_size, NULL);
	if (rel_bytes && rel_size > 0) {
		if (!current_vaddr_found) {
			return ELF_INVALID_RELOCATION;
		};

		const size_t rel_count = rel_size / sizeof(ElfRel);
		const ElfRel* rel_table = (const ElfRel*)rel_bytes;

		for (size_t i = 0; i < rel_count; i++) {
			ElfRel rel = rel_table[i];
			if (rel.r_offset + sizeof(uint32_t) > section_data_size) {
				return ELF_BUFFER_TOO_SMALL;
			};

			const uint32_t sym_index = ELF32_R_SYM(rel.r_info);
			const ElfRelocType reloc_type = ELF32_R_TYPE(rel.r_info);
			const ElfSym sym = symtab[sym_index];

			const char* sym_name = (strtab != NULL) ? (strtab + sym.st_name) : "";
			uint32_t absolute_addr = 0;

			if (strcmp(sym_name, "heap_base") == 0) {
				uint32_t heap_end = 0;
				for (size_t j = 0; j < layout_count; j++) {
					if (strcmp(layout[j].section_name, ".data") == 0 || strcmp(layout[j].section_name, ".text") == 0) {
						uint32_t sec_size = 0;
						elf_view_get_section(view, layout[j].section_name, &sec_size, NULL);
						uint32_t sec_end = layout[j].base_vaddr + sec_size;
						if (sec_end > heap_end) {
							heap_end = sec_end;
						};
					};
				};
				absolute_addr = (heap_end + 3) & ~3;
			} else {
				if (sym.st_shndx >= view->section_count) {
					return ELF_INVALID_EHDR;
				};

				const ElfSHDR* target_shdr = &view->section_headers[sym.st_shndx];
				const char* sym_sec_name = view->shstrtab + target_shdr->sh_name;

				uint8_t base_vaddr_found = 0;
				uint32_t base_vaddr = 0;

				for (size_t j = 0; j < layout_count; j++) {
					if (strcmp(layout[j].section_name, sym_sec_name) == 0) {
						base_vaddr = layout[j].base_vaddr;
						base_vaddr_found = 1;
						break;
					};
				};

				if (!base_vaddr_found) {
#if defined(DEBUG)
					fprintf(stderr, "base vaddress was not found.\n");
#endif
					return ELF_INVALID_RELOCATION;
				};

				absolute_addr = base_vaddr + sym.st_value;
			};

			uint32_t instruction;
			memcpy(&instruction, &section_data[rel.r_offset], sizeof(uint32_t));

			uint32_t ci_vaddr = current_sec_vaddr + rel.r_offset;
			switch (reloc_type) {
			case R_RTM32_WORD: {
				instruction = absolute_addr;
				break;
			};

			case R_RTM32_ELIMM: {
				int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
				uint32_t imm25 = (uint32_t)(offset >> 2) & 0x1FFFFFF;
				instruction &= ~0x1FFFFFF;
				instruction |= imm25;
				break;
			};

			case R_RTM32_VLIMM: {
				int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
				uint32_t imm24 = (uint32_t)(offset >> 2) & 0xFFFFFF;
				instruction &= ~0xFFFFFF;
				instruction |= imm24;
				break;
			};

			case R_RTM32_LLIMM: {
				uint32_t imm20 = (absolute_addr >> 2) & 0xFFFFF;
				instruction &= ~0xFFFFF;
				instruction |= imm20;
				break;
			};

			case R_RTM32_LIMM: {
				uint32_t imm19 = (absolute_addr >> 2) & 0x7FFFF;
				instruction &= ~0x7FFFF;
				instruction |= imm19;
				break;
			};

			case R_RTM32_IMM: {
				uint8_t opcode = instruction >> 27;
				uint32_t imm17;

				if (opcode >= 16 && opcode <= 21) {
					int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
					imm17 = (uint32_t)(offset >> 2) & 0x1FFFF;
				} else {
					imm17 = absolute_addr & 0x1FFFF;
				};

				instruction &= ~0x1FFFF;
				instruction |= imm17;
				break;
			};

			case R_RTM32_SIMM: {
				uint32_t imm16 = absolute_addr & 0xFFFF;
				instruction &= ~0xFFFF;
				instruction |= imm16;
				break;
			};

			case R_RTM32_AUX: {
				uint32_t imm5 = absolute_addr & 0x1F;
				instruction &= ~(0x1F << 7);
				instruction |= (imm5 << 7);
				break;
			};

			case R_RTM32_PTRLO: {
				instruction |= (absolute_addr >>  0) & 0xFFFF;
				break;
			};

			case R_RTM32_PTRHI: {
				instruction |= (absolute_addr >> 16) & 0xFFFF;
				break;
			};

			default:
#if defined(DEBUG)
				fprintf(stderr, "hit default branch, relocation was type %zu\n", (size_t)reloc_type);
#endif
				return ELF_INVALID_RELOCATION;
			};

			memcpy(&section_data[rel.r_offset], &instruction, sizeof(uint32_t));
		};
	};

	char relasection_name[40] = ".rela";
	strncat(relasection_name, section_name, sizeof(relasection_name) - strlen(relasection_name) - 1);

	uint32_t rela_size = 0;
	const uint8_t* rela_bytes = elf_view_get_section(view, relasection_name, &rela_size, NULL);
	if (rela_bytes && rela_size > 0) {
		if (!current_vaddr_found) {
			return ELF_INVALID_RELOCATION;
		};

		const size_t rela_count = rela_size / sizeof(ElfRela);
		const ElfRela* rela_table = (const ElfRela*)rela_bytes;

		for (size_t i = 0; i < rela_count; i++) {
			ElfRela rela = rela_table[i];
			if (rela.r_offset + sizeof(uint32_t) > section_data_size) {
				return ELF_BUFFER_TOO_SMALL;
			};

			const uint32_t sym_index = ELF32_R_SYM(rela.r_info);
			const ElfRelocType reloc_type = ELF32_R_TYPE(rela.r_info);
			const ElfSym sym = symtab[sym_index];

			const char* sym_name = (strtab != NULL) ? (strtab + sym.st_name) : "";
			uint32_t absolute_addr = 0;

			if (strcmp(sym_name, "heap_base") == 0) {
				uint32_t heap_end = 0;
				for (size_t j = 0; j < layout_count; j++) {
					if (strcmp(layout[j].section_name, ".data") == 0 || strcmp(layout[j].section_name, ".text") == 0) {
						uint32_t sec_size = 0;
						elf_view_get_section(view, layout[j].section_name, &sec_size, NULL);
						uint32_t sec_end = layout[j].base_vaddr + sec_size;
						if (sec_end > heap_end) {
							heap_end = sec_end;
						};
					};
				};
				absolute_addr = (uint32_t)((int32_t)((heap_end + 3) & ~3) + rela.r_addend);
			} else {
				if (sym.st_shndx >= view->section_count) {
					return ELF_INVALID_EHDR;
				};

				const ElfSHDR* target_shdr = &view->section_headers[sym.st_shndx];
				const char* sym_sec_name = view->shstrtab + target_shdr->sh_name;

				uint8_t base_vaddr_found = 0;
				uint32_t base_vaddr = 0;

				for (size_t j = 0; j < layout_count; j++) {
					if (strcmp(layout[j].section_name, sym_sec_name) == 0) {
						base_vaddr = layout[j].base_vaddr;
						base_vaddr_found = 1;
						break;
					};
				};

				if (!base_vaddr_found) {
#if defined(DEBUG)
					fprintf(stderr, "base vaddress was not found.\n");
#endif
					return ELF_INVALID_RELOCATION;
				};

				absolute_addr = (uint32_t)((int32_t)(base_vaddr + sym.st_value) + rela.r_addend);
			};

			uint32_t instruction;
			memcpy(&instruction, &section_data[rela.r_offset], sizeof(uint32_t));

			uint32_t ci_vaddr = current_sec_vaddr + rela.r_offset;
			switch (reloc_type) {
			case R_RTM32_WORD: {
				instruction = absolute_addr;
				break;
			};

			case R_RTM32_ELIMM: {
				int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
				uint32_t imm25 = (uint32_t)(offset >> 2) & 0x1FFFFFF;
				instruction &= ~0x1FFFFFF;
				instruction |= imm25;
				break;
			};

			case R_RTM32_VLIMM: {
				int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
				uint32_t imm24 = (uint32_t)(offset >> 2) & 0xFFFFFF;
				instruction &= ~0xFFFFFF;
				instruction |= imm24;
				break;
			};

			case R_RTM32_LLIMM: {
				uint32_t imm20 = (absolute_addr >> 2) & 0xFFFFF;
				instruction &= ~0xFFFFF;
				instruction |= imm20;
				break;
			};

			case R_RTM32_LIMM: {
				uint32_t imm19 = (absolute_addr >> 2) & 0x7FFFF;
				instruction &= ~0x7FFFF;
				instruction |= imm19;
				break;
			};

			case R_RTM32_IMM: {
				uint8_t opcode = instruction >> 27;
				uint32_t imm17;

				if (opcode >= 16 && opcode <= 21) {
					int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
					imm17 = (uint32_t)(offset >> 2) & 0x1FFFF;
				} else {
					imm17 = absolute_addr & 0x1FFFF;
				};

				instruction &= ~0x1FFFF;
				instruction |= imm17;
				break;
			};

			case R_RTM32_SIMM: {
				uint32_t imm16 = absolute_addr & 0xFFFF;
				instruction &= ~0xFFFF;
				instruction |= imm16;
				break;
			};

			case R_RTM32_AUX: {
				uint32_t imm5 = absolute_addr & 0x1F;
				instruction &= ~(0x1F << 7);
				instruction |= (imm5 << 7);
				break;
			};

			case R_RTM32_PTRLO: {
				instruction |= (absolute_addr >>  0) & 0xFFFF;
				break;
			};

			case R_RTM32_PTRHI: {
				instruction |= (absolute_addr >> 16) & 0xFFFF;
				break;
			};

			default:
#if defined(DEBUG)
				fprintf(stderr, "hit default branch, relocation was type %zu\n", (size_t)reloc_type);
#endif
				return ELF_INVALID_RELOCATION;
			};

			memcpy(&section_data[rela.r_offset], &instruction, sizeof(uint32_t));
		};
	};

	return ELF_SUCCESS;
};

ElfStatus elf_merge_calculate_layout(ElfLayoutMap* out_layout, const ElfView* views, size_t view_count) {
	if (!out_layout || !views || view_count == 0) {
		return ELF_MISSING_PARAMS;
	};

	memset(out_layout, 0, sizeof(*out_layout));
	for (size_t v = 0; v < view_count; v++) {
		const ElfView* view = &views[v];

		for (size_t s = 1; s < view->section_count; s++) {
			const ElfSHDR* shdr = &view->section_headers[s];

			if (!(shdr->sh_flags & SHF_ALLOC)) {
				continue;
			};

			const char* name = view->shstrtab + shdr->sh_name;
			size_t slot = SIZE_MAX;
			for (size_t i = 0; i < out_layout->section_count; ++i) {
				if (strcmp(out_layout->sections[i].name, name) == 0) {
					slot = i;
					break;
				};
			};

			if (slot == SIZE_MAX) {
				if (out_layout->section_count >= ELFIO_MAX_LAYOUT_SECTIONS) {
					return ELF_BUFFER_TOO_SMALL;
				};

				slot = out_layout->section_count++;
				memset(&out_layout->sections[slot], 0, sizeof(out_layout->sections[slot]));
				strncpy(out_layout->sections[slot].name, name, sizeof(out_layout->sections[slot].name) - 1);
				out_layout->sections[slot].alignment = 1;
			};

			size_t align = shdr->sh_addralign ? shdr->sh_addralign : 1;
			if (align > out_layout->sections[slot].alignment) {
				out_layout->sections[slot].alignment = align;
			};

			out_layout->sections[slot].size = (out_layout->sections[slot].size + align - 1) & ~(align - 1);
			out_layout->sections[slot].size += shdr->sh_size;
		};
	};

	size_t current = 0;
	for (size_t i = 0; i < out_layout->section_count; ++i) {
		size_t align = out_layout->sections[i].alignment;
		current = (current + align - 1) & ~(align - 1);
		out_layout->sections[i].base_vaddr = current;
		current += out_layout->sections[i].size;
	};

	out_layout->total_memory_needed = current;
	return ELF_SUCCESS;
};

ElfStatus elf_merge(
		uint8_t* dest, size_t capacity, const ElfLayoutMap* layout,
		const ElfView* views, size_t view_count) {
	if (!dest || !layout || !views) {
		return ELF_MISSING_PARAMS;
	};

	if (capacity < layout->total_memory_needed) {
		return ELF_BUFFER_TOO_SMALL;
	};

	memset(dest, 0, capacity);
	for (size_t l = 0; l < layout->section_count; l++) {
		const ElfLayoutSection* merged = &layout->sections[l];
		size_t dst = merged->base_vaddr;

		for (size_t v = 0; v < view_count; v++) {
			const ElfView* view = &views[v];
			uint32_t src_size = 0;

			const uint8_t* src = elf_view_get_section(view, merged->name, &src_size, NULL);
			if (!src) continue;

			const ElfSHDR* shdr = elf_view_get_section_header(view, merged->name);
			size_t align = shdr->sh_addralign? shdr->sh_addralign : 1;
			dst = (dst + align - 1) & ~(align - 1);

			memcpy(dest + dst, src, src_size);
			dst += src_size;
		};
	};

	return ELF_SUCCESS;
};
