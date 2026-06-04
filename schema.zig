const std = @import("std");
const assert = std.debug.assert;
const conn = @import("conn.zig");
const Db = conn.Db;

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
    return @Struct(.auto, null, &field_names, &field_types[0..], &[_]std.builtin.Type.StructField.Attributes{.{}} ** n);
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
    @memcpy(buf[*pos..], col.name);
    pos.* += @intCast(col.name.len);
    buf[pos.*] = ' ';
    pos.* += 1;

    const stype = comptime sqliteType(T);
    @memcpy(buf[*pos..], stype);
    pos.* += @intCast(stype.len);

    if (col._pk) {
        const s = " PRIMARY KEY";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
    }
    if (col._nn and !col._pk) {
        const s = " NOT NULL";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
    }
    if (col._uq) {
        const s = " UNIQUE";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
    }
    if (col._coll) |c| {
        const s = " COLLATE ";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
        @memcpy(buf[*pos..], c);
        pos.* += @intCast(c.len);
    }
    if (col._def) |d| {
        const s = " DEFAULT ";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
        @memcpy(buf[*pos..], d);
        pos.* += @intCast(d.len);
    }
    if (col._ref) |r| {
        const s = " REFERENCES ";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
        @memcpy(buf[*pos..], r);
        pos.* += @intCast(r.len);
    }
    if (col._chk) |c| {
        const s = " CHECK (";
        @memcpy(buf[*pos..], s);
        pos.* += @intCast(s.len);
        @memcpy(buf[*pos..], c);
        pos.* += @intCast(c.len);
        buf[pos.*] = ')';
        pos.* += 1;
    }
}

pub fn create_stmt(comptime TableMeta: type, comptime if_not_exists: bool) []const u8 {
    var buf: [4096]u8 = undefined;
    var pos: u32 = 0;

    const head = "CREATE TABLE ";
    @memcpy(buf[0..head.len], head);
    pos += @intCast(head.len);

    if (if_not_exists) {
        const nie = "IF NOT EXISTS ";
        @memcpy(buf[pos..], nie);
        pos += @intCast(nie.len);
    }

    @memcpy(buf[pos..], TableMeta.table_name);
    pos += @intCast(TableMeta.table_name.len);

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
    const field_info = @typeInfo(ValuesType).@"struct".fields;
    assert(field_info.len > 0);

    var buf: [2000]u8 = undefined;
    var pos: u32 = 0;

    const header = "INSERT INTO ";
    @memcpy(buf[0..header.len], header);
    pos += @intCast(header.len);

    @memcpy(buf[pos..], TableMeta.table_name);
    pos += @intCast(TableMeta.table_name.len);
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
        @memcpy(buf[pos..], field.name);
        pos += @intCast(field.name.len);
    }

    const middle = ") VALUES (";
    @memcpy(buf[pos..], middle);
    pos += @intCast(middle.len);

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
    const sql = comptime insert_stmt(TableMeta, @TypeOf(values));
    try db.exec_args(sql, values);
}
