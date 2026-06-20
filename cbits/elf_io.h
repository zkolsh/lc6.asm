#pragma once
// References:
// [1]: https://refspecs.linuxfoundation.org/elf/elf.pdf
// [2]: https://gabi.xinuos.com/elf/a-emachine.html

#if !defined(STATIC_ASSERT)
#define STATIC_ASSERT(COND, MSG) typedef char static_assertion_##MSG[(COND) ? 1 : -1]
#endif

#include <stddef.h>
#include <stdint.h>

typedef uint8_t ElfStatus;
enum {
	ELF_SUCCESS = 0,
	ELF_ARCH_MISMATCH,
	ELF_BUFFER_TOO_SMALL,
	ELF_ENDIANNESS_MISMATCH,
	ELF_INVALID_EHDR,
	ELF_INVALID_MAGIC,
	ELF_MISSING_PARAMS,
	ELF_WORDSIZE_MISMATCH,
	ELF_SYMBOL_NOT_FOUND,
	ELF_SYMBOL_TABLE_NOT_FOUND,
	ELF_INVALID_RELOCATION,
};

const char* elf_status_str(const ElfStatus status);

STATIC_ASSERT(sizeof(uint8_t)  == 1, primitive_ints_size_mismatch);
STATIC_ASSERT(sizeof(uint16_t) == 2, primitive_ints_size_mismatch);
STATIC_ASSERT(sizeof(uint32_t) == 4, primitive_ints_size_mismatch);
STATIC_ASSERT(sizeof(int32_t)  == 4, primitive_ints_size_mismatch);

STATIC_ASSERT(_Alignof(uint8_t)  == 1, primitive_ints_alignment_mismatch);
STATIC_ASSERT(_Alignof(uint16_t) == 2, primitive_ints_alignment_mismatch);
STATIC_ASSERT(_Alignof(uint32_t) == 4, primitive_ints_alignment_mismatch);
STATIC_ASSERT(_Alignof(int32_t)  == 4, primitive_ints_alignment_mismatch);

typedef uint16_t ElfType;
enum {
	ET_NONE	= 0,
	ET_REL	= 1,
	ET_EXEC	= 2,
	ET_DYN	= 3,
	ET_CORE	= 4,
	ET_LOPROC	= 0xff00,
	ET_HIPROC	= 0xffff,
};

const char* elf_type_str(const ElfType type);

// Free according to [2]
#define EMACHINE_RTM32	0x4B6

#define EI_NIDENT 16
#define EV_CURRENT 1
typedef struct __attribute__((packed)) {
	uint8_t  e_ident[EI_NIDENT];
	ElfType  e_type;
	uint16_t e_machine;
	uint32_t e_version;
	uint32_t e_entry;
	uint32_t e_phoff;
	uint32_t e_shoff;
	uint32_t e_flags;
	uint16_t e_ehsize;
	uint16_t e_phentsize;
	uint16_t e_phnum;
	uint16_t e_shentsize;
	uint16_t e_shnum;
	uint16_t e_shstrndx;
} ElfEHDR;

typedef struct __attribute__((packed)) {
	uint32_t sh_name;
	uint32_t sh_type;
	uint32_t sh_flags;
	uint32_t sh_addr;
	uint32_t sh_offset;
	uint32_t sh_size;
	uint32_t sh_link;
	uint32_t sh_info;
	uint32_t sh_addralign;
	uint32_t sh_entsize;
} ElfSHDR;

typedef struct __attribute__((packed)) {
	uint32_t st_name;
	uint32_t st_value;
	uint32_t st_size;
	uint8_t  st_info;
	uint8_t  st_other;
	uint16_t st_shndx;
} ElfSym;

typedef uint32_t ElfShType;
enum {
	SHT_NULL     = 0,
	SHT_PROGBITS = 1,
	SHT_SYMTAB   = 2,
	SHT_STRTAB   = 3,
	SHT_RELA     = 4,
	SHT_NOBITS   = 8,
	SHT_REL      = 9,
};

const char* elf_sh_type_str(const ElfShType type);

typedef uint32_t ElfShFlags;
enum {
	SHF_NONE      = (0 << 0),
	SHF_WRITE     = (1 << 0),
	SHF_ALLOC     = (1 << 1),
	SHF_EXECINSTR = (1 << 2),
};

typedef struct {
	const char* name;
	const uint8_t* data;
	uint32_t size;
	ElfShType type;
	ElfShFlags flags;
	uint32_t addralign;
	uint32_t link;
	uint32_t info;
	uint32_t entsize;
} ElfRawSection;

size_t elf_writer_calculate_size(const ElfRawSection* sections, size_t count);
ElfStatus elf_writer_serialize(
		uint8_t* dest_file_buffer, size_t dest_capacity,
		ElfType out_type, uint32_t entry_point,
		const ElfRawSection* sections, size_t count);

typedef struct {
	const uint8_t* buffer_view;
	size_t buffer_size;
	const ElfEHDR* header;
	const ElfSHDR* section_headers;
	size_t section_count;
	const char* shstrtab; // elfspeak for "section header string table pointer"
} ElfView;

ElfStatus elf_view_parse(ElfView* output, const size_t size, const uint8_t* buffer);

ElfStatus elf_view_peek_symbol_value(const ElfView* view, const char* name, uint32_t* out_value);
const ElfSHDR* elf_view_get_section_header(const ElfView* view, const char* name);
const uint8_t* elf_view_get_section(const ElfView* view, const char* name, uint32_t* out_size, uint32_t* out_flags);

typedef struct __attribute__((packed)) {
	uint32_t r_offset;
	uint32_t r_info;
} ElfRel;

typedef struct __attribute__((packed)) {
	uint32_t r_offset;
	uint32_t r_info;
	int32_t  r_addend;
} ElfRela;

typedef uint8_t ElfRelocType;
enum {
	R_RTM32_NONE   = 0,
	R_RTM32_RTYPE  = 1,
	R_RTM32_TAIL16 = 2,
	R_RTM32_TAIL27 = 3,
};

#define ELF32_R_SYM(i)   ((i) >> 8)
#define ELF32_R_TYPE(i)  ((uint8_t)(i))
#define ELF32_R_INFO(s, t) (((s) << 8) + (uint8_t)(t))

ElfStatus elf_view_patch_relocations(
		const ElfView* view, uint8_t* section_data, size_t section_data_size,
		const char* section_name, uint32_t text_base_vaddr, uint32_t data_base_vaddr);

typedef struct {
	size_t text_size;
	size_t text_align;
	size_t data_size;
	size_t data_align;
	size_t total_memory_needed; 
} ElfLayoutMap;

ElfStatus elf_merge_calculate_layout(ElfLayoutMap* out_layout, const ElfView* views, size_t view_count);

ElfStatus elf_merge(
		uint8_t* dest_memory, size_t dest_capacity,
		const ElfLayoutMap* layout, const ElfView* views, size_t view_count);
