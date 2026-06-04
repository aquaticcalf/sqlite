const std = @import("std");
const assert = std.debug.assert;
const conn = @import("conn.zig");
const Db = conn.Db;

fn copy(buf: anytype, pos: *u32, src: []const u8) void {
    @memcpy(buf[pos.*..][0..src.len], src);
    pos.* += @intCast(src.len);
}

fn sqliteType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => "INTEGER",
        .float, .comptime_float => "REAL",
        .bool => "INTEGER",
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return "TEXT";
            if (ptr.size == .many and ptr.child == u8) return "BLOB";
            @compileError("unsupported column type " ++ @typeName(T));
        },
        .optional => sqliteType(@typeInfo(T).optional.child),
        .@"enum" => "TEXT",
        else => @compileError("unsupported column type " ++ @typeName(T)),
    };
}

fn ColBuilder(comptime T: type) type {
    return struct {
        name: []const u8 = "",
        field_type: type = T,
        _pk: bool = false,
        _nn: bool = false,
        _uq: bool = false,
        _coll: ?[]const u8 = null,
        _def: ?[]const u8 = null,
        _ref: ?[]const u8 = null,
        _chk: ?[]const u8 = null,

        pub fn primary_key(self: @This()) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = true, ._nn = self._nn, ._uq = self._uq, ._coll = self._coll, ._def = self._def, ._ref = self._ref, ._chk = self._chk };
        }
        pub fn not_null(self: @This()) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = self._pk, ._nn = true, ._uq = self._uq, ._coll = self._coll, ._def = self._def, ._ref = self._ref, ._chk = self._chk };
        }
        pub fn unique(self: @This()) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = self._pk, ._nn = self._nn, ._uq = true, ._coll = self._coll, ._def = self._def, ._ref = self._ref, ._chk = self._chk };
        }
        pub fn collate(self: @This(), c: []const u8) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = self._pk, ._nn = self._nn, ._uq = self._uq, ._coll = c, ._def = self._def, ._ref = self._ref, ._chk = self._chk };
        }
        pub fn default(self: @This(), d: []const u8) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = self._pk, ._nn = self._nn, ._uq = self._uq, ._coll = self._coll, ._def = d, ._ref = self._ref, ._chk = self._chk };
        }
        pub fn references(self: @This(), r: []const u8) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = self._pk, ._nn = self._nn, ._uq = self._uq, ._coll = self._coll, ._def = self._def, ._ref = r, ._chk = self._chk };
        }
        pub fn check(self: @This(), c: []const u8) @This() {
            return .{ .name = self.name, .field_type = T, ._pk = self._pk, ._nn = self._nn, ._uq = self._uq, ._coll = self._coll, ._def = self._def, ._ref = self._ref, ._chk = c };
        }
    };
}

pub fn Column(comptime name: []const u8, comptime T: type) ColBuilder(T) {
    return .{ .name = name };
}

fn deriveRowType(comptime cols: anytype) type {
    const ColsType = @TypeOf(cols);
    const col_fields = @typeInfo(ColsType).@"struct".fields;
    const n = col_fields.len;
    var field_names: [n][]const u8 = undefined;
    var field_types: [n]type = undefined;
    inline for (col_fields, 0..) |field, i| {
        const col = @field(cols, field.name);
        field_names[i] = field.name;
        field_types[i] = col.field_type;
    }
    return @Struct(.auto, null, &field_names, &field_types[0..], &([_]std.builtin.Type.StructField.Attributes{.{}} ** n));
}

pub fn table(comptime name: []const u8, comptime cols: anytype) type {
    assert(name.len > 0);
    const ColsType = @TypeOf(cols);
    const col_fields = @typeInfo(ColsType).@"struct".fields;
    assert(col_fields.len > 0);

    return struct {
        pub const table_name = name;
        pub const columns = cols;
        pub const Row = deriveRowType(cols);
    };
}

fn emitColumn(buf: *[4096]u8, pos: *u32, comptime T: type, col: anytype) void {
    copy(buf, pos, col.name);
    buf[pos.*] = ' ';
    pos.* += 1;

    const stype = comptime sqliteType(T);
    copy(buf, pos, stype);

    if (col._pk) copy(buf, pos, " PRIMARY KEY");
    if (col._nn and !col._pk) copy(buf, pos, " NOT NULL");
    if (col._uq) copy(buf, pos, " UNIQUE");
    if (col._coll) |c| {
        copy(buf, pos, " COLLATE ");
        copy(buf, pos, c);
    }
    if (col._def) |d| {
        copy(buf, pos, " DEFAULT ");
        copy(buf, pos, d);
    }
    if (col._ref) |r| {
        copy(buf, pos, " REFERENCES ");
        copy(buf, pos, r);
    }
    if (col._chk) |c| {
        copy(buf, pos, " CHECK (");
        copy(buf, pos, c);
        buf[pos.*] = ')';
        pos.* += 1;
    }
}

pub fn create_stmt(comptime TableMeta: type, comptime if_not_exists: bool) []const u8 {
    var buf: [4096]u8 = undefined;
    var pos: u32 = 0;

    const bp: *[4096]u8 = &buf;
    copy(bp, &pos, "CREATE TABLE ");
    if (if_not_exists) copy(bp, &pos, "IF NOT EXISTS ");
    copy(bp, &pos, TableMeta.table_name);
    buf[pos] = ' ';
    pos += 1;
    buf[pos] = '(';
    pos += 1;

    const ColsType = @TypeOf(TableMeta.columns);
    const col_fields = @typeInfo(ColsType).@"struct".fields;
    inline for (col_fields, 0..) |field, i| {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
            buf[pos] = ' ';
            pos += 1;
        }
        const col = @field(TableMeta.columns, field.name);
        emitColumn(&buf, &pos, col.field_type, col);
    }

    buf[pos] = ')';
    pos += 1;
    assert(pos <= buf.len);
    return buf[0..pos];
}

pub fn insert_stmt(comptime TableMeta: type, comptime ValuesType: type) []const u8 {
    return insert_stmt_prefix(TableMeta, ValuesType, "");
}

pub fn insert_stmt_prefix(comptime TableMeta: type, comptime ValuesType: type, comptime prefix: []const u8) []const u8 {
    const field_info = @typeInfo(ValuesType).@"struct".fields;
    assert(field_info.len > 0);

    var buf: [2000]u8 = undefined;
    var pos: u32 = 0;
    const bp: *[2000]u8 = &buf;

    copy(bp, &pos, "INSERT ");
    if (prefix.len > 0) {
        copy(bp, &pos, prefix);
        buf[pos] = ' ';
        pos += 1;
    }
    copy(bp, &pos, "INTO ");
    copy(bp, &pos, TableMeta.table_name);
    buf[pos] = ' ';
    pos += 1;
    buf[pos] = '(';
    pos += 1;

    inline for (field_info, 0..) |field, i| {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
            buf[pos] = ' ';
            pos += 1;
        }
        copy(bp, &pos, field.name);
    }

    copy(bp, &pos, ") VALUES (");

    inline for (field_info, 0..) |_, i| {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        buf[pos] = '?';
        pos += 1;
    }

    buf[pos] = ')';
    pos += 1;

    assert(pos <= buf.len);
    return buf[0..pos];
}

pub fn insert(db: *Db, comptime TableMeta: type, values: anytype) !void {
    const sql = comptime insert_stmt_prefix(TableMeta, @TypeOf(values), "");
    try db.exec_args(sql, values);
}

pub fn insert_or_ignore(db: *Db, comptime TableMeta: type, values: anytype) !void {
    const sql = comptime insert_stmt_prefix(TableMeta, @TypeOf(values), "OR IGNORE");
    try db.exec_args(sql, values);
}
