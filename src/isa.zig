pub const Register = enum {
    t0,
    t1,
    t2,
    t3,
    s0,
    s1,
    s2,
    s3,
    s4,
    s5,
    ra,
    gp,
    sp,
    fp,
    a0,
    a1,
};

pub const DataDirective = enum {
    asciiz,
    byte,
    nascii,
    pad,
    ptr,
    word,
};

pub const RelocationMode = enum {
    rtype,
    tail16,
    tail8a,
    tail8r,
};

pub const InstructionName = enum {
    rtype,
    j,
    jal,
    andi,
    andih,
    ori,
    orih,
    xori,
    xorih,
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
    bgt,
    ble,
    bge,
    slti,
    sltiu,
    addi,

    pub const Info = struct {
        op: u5,
    };

    pub fn getInfo(self: InstructionName) Info {
        return switch (self) {
            .rtype => .{.op = 0b00000},
            .j     => .{.op = 0b00010},
            .jal   => .{.op = 0b00011},
            .andi  => .{.op = 0b00100},
            .andih => .{.op = 0b00100},
            .ori   => .{.op = 0b00100},
            .orih  => .{.op = 0b00101},
            .xori  => .{.op = 0b00100},
            .xorih => .{.op = 0b00100},
            .lw    => .{.op = 0b01000},
            .sw    => .{.op = 0b01001},
            .sh    => .{.op = 0b01010},
            .sb    => .{.op = 0b01011},
            .lh    => .{.op = 0b01100},
            .lhu   => .{.op = 0b01101},
            .lb    => .{.op = 0b01110},
            .lbu   => .{.op = 0b01111},
            .beq   => .{.op = 0b10000},
            .bne   => .{.op = 0b10001},
            .blt   => .{.op = 0b10010},
            .bgt   => .{.op = 0b10011},
            .ble   => .{.op = 0b10100},
            .bge   => .{.op = 0b10101},
            .slti  => .{.op = 0b10110},
            .sltiu => .{.op = 0b10111},
            .addi  => .{.op = 0b11000},
        };
    }
};

pub const RType = enum {
    sll,
    srl,
    sra,
    sllr,
    srlr,
    srar,
    cfs,
    cts,
    @"and",
    @"or",
    xor,
    nor,
    slt,
    sltu,
    jr,
    jalr,
    lhx,
    lhux,
    lbx,
    lbux,
    lwx,
    mul,
    mulh,
    mulhu,
    div,
    divu,
    rest,
    restu,
    add,
    sub,
    trap,
    rft,

    pub const Funct = struct {
        code: u6,
    };

    pub fn getFunct(self: RType) Funct {
        return switch(self) {
            .sll    => .{.code = 0b000000},
            .srl    => .{.code = 0b000001},
            .sra    => .{.code = 0b000010},
            .sllr   => .{.code = 0b000011},
            .srlr   => .{.code = 0b000100},
            .srar   => .{.code = 0b000101},
            .cfs    => .{.code = 0b000110},
            .cts    => .{.code = 0b000111},
            .@"and" => .{.code = 0b001000},
            .@"or"  => .{.code = 0b001001},
            .xor    => .{.code = 0b001010},
            .nor    => .{.code = 0b001011},
            .slt    => .{.code = 0b001100},
            .sltu   => .{.code = 0b001101},
            .jr     => .{.code = 0b001110},
            .jalr   => .{.code = 0b001111},
            .lhx    => .{.code = 0b010000},
            .lhux   => .{.code = 0b010001},
            .lbx    => .{.code = 0b010010},
            .lbux   => .{.code = 0b010011},
            .lwx    => .{.code = 0b010100},
            .mul    => .{.code = 0b010101},
            .mulh   => .{.code = 0b010110},
            .mulhu  => .{.code = 0b010111},
            .div    => .{.code = 0b011000},
            .divu   => .{.code = 0b011001},
            .rest   => .{.code = 0b011010},
            .restu  => .{.code = 0b011011},
            .add    => .{.code = 0b011100},
            .sub    => .{.code = 0b011101},
            .trap   => .{.code = 0b100000},
            .rft    => .{.code = 0b100001},
        };
    }
};

pub const Section = enum {
    data,
    text,
};

pub const PreprocessorDirective = enum {
    define,
    embed,
    include,
    macro,
};

pub const PreprocessorBuiltin = enum {
    endif,
    file,
    @"if",
    ifdef,
    ifndef,
    line,
};
