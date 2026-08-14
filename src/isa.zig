pub const Register = enum {
    zero,
    ra,
    k0,
    k1,
    lr0,
    lr1,
    lr2,
    lr3,
    a0,
    a1,
    a2,
    a3,
    a4,
    a5,
    t0,
    t1,
    t2,
    t3,
    t4,
    t5,
    s0,
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    fp,
    gp,
    sp,
    at,
};

pub const SpecialRegister = enum {
    psw,
    ecr,
    epc,
    esr,
    bva,
    vbr,
    pir,
};

pub const PreprocessorDirective = enum {
    define,
    @"else",
    embed,
    endif,
    endmacro,
    filename,
    ifdef,
    ifndef,
    include,
    line,
    macro,
};

pub const PreprocessorBuiltin = enum {
    alignOf,
    sizeOf,
    stringify,
};

pub const DataDirective = enum {
    asciiz,
    byte,
    nascii,
    pad,
    ptr,
    section,
    short,
    word,
    lo16,
    hi16,
};

pub const RelocationMode = enum {
    word, // .ptr
    elimm,
    vlimm,
    llimm,
    limm,
    imm,
    simm,
    aux,
    ptrlo, // .lo16
    ptrhi, // .hi16 
};

pub const ImmediateKind = enum {
    elimm,
    vlimm,
    llimm,
    limm,
    imm,
    simm,
    aux,
};

pub fn Immediate(comptime T: type) type {
    return union(enum) {
        static: T,
        dynamic: []const u8,
        pointer: struct {
            high: bool,
            label: []const u8,
        }
    };
}

pub const InstructionInfo = struct {
    opcode: u5,
    immtype: ?ImmediateKind,
    reltype: ?RelocationMode,
};

pub const RTypeMnemo = enum {
    sll,
    rlc,
    srl,
    sra,
    sllr,
    rlcr,
    srlr,
    srar,
    @"and",
    @"or",
    nor,
    xor,
    add,
    sub,
    slt,
    sltu,
    lhx,
    lhux,
    lbx,
    lbux,
    lwx,
    swx,
    shx,
    sbx,
    mul,
    mulh,
    mulhu,
    mulhsu,
    div,
    divu,
    rest,
    restu,
    cfs,
    cts,
    trap,
    rft,
};

pub const RType = struct {
    funct: RTypeMnemo,
    rs: Register,
    rt: Register,
    rd: Register,
    aux: Immediate(u5),

    pub const RInfo = struct {
        funct: u6,
    };

    pub inline fn getRInfo(kind: RTypeMnemo) RInfo {
        return switch(kind) {
            .sll    => .{.funct = 0b000000},
            .rlc    => .{.funct = 0b000001},
            .srl    => .{.funct = 0b000010},
            .sra    => .{.funct = 0b000011},
            .sllr   => .{.funct = 0b000100},
            .rlcr   => .{.funct = 0b000101},
            .srlr   => .{.funct = 0b000110},
            .srar   => .{.funct = 0b000111},
            .@"and" => .{.funct = 0b001000},
            .@"or"  => .{.funct = 0b001001},
            .xor    => .{.funct = 0b001010},
            .nor    => .{.funct = 0b001011},
            .add    => .{.funct = 0b001100},
            .sub    => .{.funct = 0b001101},
            .slt    => .{.funct = 0b001110},
            .sltu   => .{.funct = 0b001111},
            .lhx    => .{.funct = 0b010000},
            .lhux   => .{.funct = 0b010001},
            .lbx    => .{.funct = 0b010010},
            .lbux   => .{.funct = 0b010011},
            .lwx    => .{.funct = 0b010100},
            .swx    => .{.funct = 0b010101},
            .shx    => .{.funct = 0b010110},
            .sbx    => .{.funct = 0b010111},
            .mul    => .{.funct = 0b011000},
            .mulh   => .{.funct = 0b011001},
            .mulhu  => .{.funct = 0b011010},
            .mulhsu => .{.funct = 0b011011},
            .div    => .{.funct = 0b011100},
            .divu   => .{.funct = 0b011101},
            .rest   => .{.funct = 0b011110},
            .restu  => .{.funct = 0b011111},
            .cfs    => .{.funct = 0b100000},
            .cts    => .{.funct = 0b100001},
            .trap   => .{.funct = 0b100010},
            .rft    => .{.funct = 0b100011},
        };
    }
};

pub const ITypeMnemo = enum {
    jr,
    jalr,
    jalrx,
    addi,
    andi,
    lci,
    ani,
    anh,
    ori,
    orh,
    xori,
    xorh,
    lw,
    sw,
    sh,
    sb,
    lh,
    lhu,
    lb,
    lbu,
    beq,
    bne,
    blt,
    bge,
    bltu,
    bgeu,
    slti,
    sltiu,
};

pub const IType = struct {
    opcode: ITypeMnemo,
    rs: Register,
    rt: Register,
    imm: Immediate(u25),
    linkRegister: Register,

    pub inline fn getInfo(kind: ITypeMnemo) InstructionInfo {
        return switch (kind) {
            .jr    => .{.opcode = 0b00010, .immtype = .llimm, .reltype = .llimm},
            .jalr  => .{.opcode = 0b00010, .immtype = .llimm, .reltype = .llimm},
            .jalrx => .{.opcode = 0b00010, .immtype = .llimm, .reltype = .llimm},
            .addi  => .{.opcode = 0b00011, .immtype = .imm,  .reltype = .imm},
            .andi  => .{.opcode = 0b00100, .immtype = .simm,  .reltype = .simm},
            .lci   => .{.opcode = 0b00100, .immtype = .simm,  .reltype = .simm},
            .ani   => .{.opcode = 0b00101, .immtype = .simm,  .reltype = .simm},
            .anh   => .{.opcode = 0b00101, .immtype = .simm,  .reltype = .simm},
            .ori   => .{.opcode = 0b00110, .immtype = .simm,  .reltype = .simm},
            .orh   => .{.opcode = 0b00110, .immtype = .simm,  .reltype = .simm},
            .xori  => .{.opcode = 0b00111, .immtype = .simm,  .reltype = .simm},
            .xorh  => .{.opcode = 0b00111, .immtype = .simm,  .reltype = .simm},
            .lw    => .{.opcode = 0b01000, .immtype = .imm,   .reltype = .imm},
            .sw    => .{.opcode = 0b01001, .immtype = .imm,   .reltype = .imm},
            .sh    => .{.opcode = 0b01010, .immtype = .imm,   .reltype = .imm},
            .sb    => .{.opcode = 0b01011, .immtype = .imm,   .reltype = .imm},
            .lh    => .{.opcode = 0b01100, .immtype = .imm,   .reltype = .imm},
            .lhu   => .{.opcode = 0b01101, .immtype = .imm,   .reltype = .imm},
            .lb    => .{.opcode = 0b01110, .immtype = .imm,   .reltype = .imm},
            .lbu   => .{.opcode = 0b01111, .immtype = .imm,   .reltype = .imm},
            .beq   => .{.opcode = 0b10000, .immtype = .imm,   .reltype = .imm},
            .bne   => .{.opcode = 0b10001, .immtype = .imm,   .reltype = .imm},
            .blt   => .{.opcode = 0b10010, .immtype = .imm,   .reltype = .imm},
            .bge   => .{.opcode = 0b10011, .immtype = .imm,   .reltype = .imm},
            .bltu  => .{.opcode = 0b10100, .immtype = .imm,   .reltype = .imm},
            .bgeu  => .{.opcode = 0b10101, .immtype = .imm,   .reltype = .imm},
            .slti  => .{.opcode = 0b10110, .immtype = .imm,   .reltype = .imm},
            .sltiu => .{.opcode = 0b10111, .immtype = .imm,   .reltype = .imm},
        };
    }
};

pub const JTypeMnemo = enum {
    j,
    jal,
    jalx,
};

pub const JType = struct {
    opcode: JTypeMnemo,
    imm: Immediate(u25),
    linkRegister: Register,

    pub inline fn getInfo(kind: JTypeMnemo) InstructionInfo {
        return switch (kind) {
            .j    => .{.opcode = 0b00001, .immtype = .elimm, .reltype = .elimm},
            .jal  => .{.opcode = 0b00001, .immtype = .elimm, .reltype = .elimm},
            .jalx => .{.opcode = 0b00001, .immtype = .vlimm, .reltype = .vlimm},
        };
    }
};

pub const Instruction = union(enum) {
    rtype: RType,
    itype: IType,
    jtype: JType,
};

pub const Padding = struct {
    size: usize,
    alignment: usize,
};

pub const Directive = union(enum) {
    section: []const u8,
    bytes: []const u8,
    shorts: []const u16,
    words: []const u32,
    asciiz: []const u8,
    nascii: []const u8,
    padding: Padding,
    ptr: []const u8,
    lo16: []const u8,
    hi16: []const u8,
};

pub const Statement = struct {
    label: []const u8,
    value: union(enum) {
        section: []const u8,
        bytes: []const u8,
        shorts: []const u16,
        words: []const u32,
        asciiz: []const u8,
        nascii: []const u8,
        padding: Padding,
        ptr: []const u8,
        lo16: []const u8,
        hi16: []const u8,
        rtype: RType,
        itype: IType,
        jtype: JType,
    }
};
