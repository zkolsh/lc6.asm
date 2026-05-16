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
    word,
};

pub const RelocationMode = enum {
    tail8a,
    tail8r,
    tail16,
};

pub const InstructionName = enum {
    add,
    lw,
    sw,
    beq,
    j,
    halt,

    pub const Info = struct {
        op: u4,
        reloc: ?RelocationMode,
    };

    pub fn getInfo(self: InstructionName) Info {
        return switch (self) {
            .add  => .{.op =  0, .reloc = null},
            .lw   => .{.op =  2, .reloc = .tail8a},
            .sw   => .{.op =  3, .reloc = .tail8a},
            .beq  => .{.op =  4, .reloc = .tail8r},
            .j    => .{.op = 14, .reloc = .tail16},
            .halt => .{.op = 15, .reloc = null},
        };
    }
};

pub const Section = enum {
    data,
    text,
};
