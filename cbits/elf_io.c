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

	// const size_t required_size = elf_writer_calculate_size(sections, count);
	// if (dest_capacity < required_size) return ELF_BUFFER_TOO_SMALL;

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
		strcat((char*)str_ptr, sections[i].name);
		str_ptr += 1 + strlen(sections[i].name);
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
			.sh_addr      = 0,
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
		const char* section_name, uint32_t text_base_vaddr, uint32_t data_base_vaddr) {
	if (!view || !section_data) return ELF_MISSING_PARAMS;

	char relsection_name[40] = ".rel";
	strcat(relsection_name, section_name);

	uint32_t rel_size = 0;
	const uint8_t* rel_bytes = elf_view_get_section(view, relsection_name, &rel_size, NULL);
	if (!rel_bytes || rel_size == 0) {
		/* no relocations to patch. */
		return ELF_SUCCESS; 
	};

	const ElfSHDR* symtab_shdr = elf_view_get_section_header(view, ".symtab");
	if (!symtab_shdr) return ELF_INVALID_EHDR;
	const ElfSym* symtab = (const ElfSym*)(view->buffer_view + symtab_shdr->sh_offset);

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

		if (sym.st_shndx >= view->section_count) {
			return ELF_INVALID_EHDR;
		};

		const ElfSHDR* target_shdr = &view->section_headers[sym.st_shndx];
		const char* sym_sec_name = view->shstrtab + target_shdr->sh_name;

		uint32_t base_vaddr = 0;
		if (strcmp(sym_sec_name, ".text") == 0) {
			base_vaddr = text_base_vaddr;
		} else if (strcmp(sym_sec_name, ".data") == 0) {
			base_vaddr = data_base_vaddr;
		} else {
#if defined(DEBUG)
			fprintf(stderr, "[elf]: WARNING: relocations on section %s is unsupported.\n", sym_sec_name);
#endif
			continue;
		};

		const uint32_t absolute_addr = base_vaddr + sym.st_value;
		uint32_t instruction;
		memcpy(&instruction, &section_data[rel.r_offset], sizeof(uint32_t));

		switch (reloc_type) {
		case R_RTM32_RTYPE: {
			const uint32_t imm5 = (absolute_addr) & 0x1F;
			instruction &= ~(0x1F << 22);
			instruction |= (imm5 << 22);
			break;
		};

		case R_RTM32_LO16: {
			uint32_t imm16 = absolute_addr & 0xFFFF;
			instruction &= ~0xFFFF;
			instruction |= imm16;
			break;
		};

		case R_RTM32_HI16: {
			uint32_t imm16 = (absolute_addr >> 16) & 0xFFFF;
			instruction &= ~0xFFFF;
			instruction |= imm16;
			break;
		};

		case R_RTM32_PC16: {
			uint32_t patched_vaddr = (strcmp(section_name, ".text") == 0)? text_base_vaddr : data_base_vaddr;
			uint32_t ci_vaddr = patched_vaddr + rel.r_offset;
			int32_t offset = (int32_t)absolute_addr - (int32_t)(ci_vaddr + 4);
			uint32_t imm16 = (uint32_t)(offset >> 2) & 0xFFFF;
			instruction &= ~0xFFFF;
			instruction |= imm16;
			break;
		};

		case R_RTM32_TAIL27: {
			uint32_t imm27 = (absolute_addr >> 2) & 0x07FFFFFF;
			instruction &= ~0x07FFFFFF;
			instruction |= imm27;
			break;
		};

		case R_RTM32_WORD: {
			instruction = absolute_addr;
			break;
		};

		default:
			return ELF_INVALID_RELOCATION;
		};

		memcpy(&section_data[rel.r_offset], &instruction, sizeof(uint32_t));
	};

	return ELF_SUCCESS;
};

ElfStatus elf_merge_calculate_layout(ElfLayoutMap* out_layout, const ElfView* views, size_t view_count) {
	if (!out_layout || !views || view_count == 0) return ELF_MISSING_PARAMS;
	out_layout->text_size = out_layout->data_size = 0;
	out_layout->text_align = out_layout->data_align = 1;

	for (size_t v = 0; v < view_count; v++) {
		const ElfView* view = &views[v];

		for (size_t s = 1; s < view->section_count; s++) {
			const ElfSHDR* shdr = &view->section_headers[s];
			const char* name = view->shstrtab + shdr->sh_name;

			if (strcmp(name, ".text") == 0) {
				uint32_t align = shdr->sh_addralign ? shdr->sh_addralign : 1;
				if (align > out_layout->text_align) out_layout->text_align = align;
				out_layout->text_size = (out_layout->text_size + (align - 1)) & ~(align - 1);
				out_layout->text_size += shdr->sh_size;
			} else if (strcmp(name, ".data") == 0) {
				uint32_t align = shdr->sh_addralign ? shdr->sh_addralign : 1;
				if (align > out_layout->data_align) out_layout->data_align = align;
				out_layout->data_size = (out_layout->data_size + (align - 1)) & ~(align - 1);
				out_layout->data_size += shdr->sh_size;
#if defined(DEBUG)
			} else {
				fprintf(stderr, "[elf]: WARNING: not merging section %s\n", name);
#endif
			};
		}
	}

	uint32_t total = 0;
	total = (total + (out_layout->text_align - 1)) & ~(out_layout->text_align - 1);
	total += out_layout->text_size;
	total = (total + (out_layout->data_align - 1)) & ~(out_layout->data_align - 1);
	total += out_layout->data_size;
	out_layout->total_memory_needed = total;
	return ELF_SUCCESS;
};

ElfStatus elf_merge(
		uint8_t* dest_memory, size_t dest_capacity,
		const ElfLayoutMap* layout, const ElfView* views, size_t view_count) {
	if (!dest_memory || !layout || !views || view_count == 0) return ELF_MISSING_PARAMS;
	if (dest_capacity < layout->total_memory_needed) return ELF_BUFFER_TOO_SMALL;

	uint32_t current_offset = 0;
	const uint32_t text_start = (current_offset + (layout->text_align - 1)) & ~(layout->text_align - 1);
	uint32_t text_ptr = text_start;
	current_offset = text_start + layout->text_size;

	const uint32_t data_start = (current_offset + (layout->data_align - 1)) & ~(layout->data_align - 1);
	uint32_t data_ptr = data_start;
	current_offset = data_start + layout->data_size;

	for (size_t v = 0; v < view_count; v++) {
		const ElfView* view = &views[v];

		uint32_t src_size = 0;
		const uint8_t* src_text = elf_view_get_section(view, ".text", &src_size, NULL);
		if (src_text && src_size > 0) {
			const ElfSHDR* shdr = elf_view_get_section_header(view, ".text");
			uint32_t align = shdr->sh_addralign ? shdr->sh_addralign : 1;
			text_ptr = (text_ptr + (align - 1)) & ~(align - 1);

			memcpy(&dest_memory[text_ptr], src_text, src_size);
			text_ptr += src_size;
		};

		const uint8_t* src_data = elf_view_get_section(view, ".data", &src_size, NULL);
		if (src_data && src_size > 0) {
			const ElfSHDR* shdr = elf_view_get_section_header(view, ".data");
			uint32_t align = shdr->sh_addralign ? shdr->sh_addralign : 1;
			data_ptr = (data_ptr + (align - 1)) & ~(align - 1);

			memcpy(&dest_memory[data_ptr], src_data, src_size);
			data_ptr += src_size;
		};
	};

	return ELF_SUCCESS;
};
