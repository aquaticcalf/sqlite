const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

/// Error wraps every non-OK sqlite3 result code into a Zig error set.
/// We map the full SQLite result space rather than collapsing into a
/// single error so that callers can distinguish, for example, a
/// constraint violation from a disk I/O failure.
pub const Error = error{
    SqliteError,
    SqliteInternal,
    SqlitePerm,
    SqliteAbort,
    SqliteBusy,
    SqliteLocked,
    SqliteNoMem,
    SqliteReadOnly,
    SqliteInterrupt,
    SqliteIOErr,
    SqliteCorrupt,
    SqliteNotFound,
    SqliteFull,
    SqliteCantOpen,
    SqliteProtocol,
    SqliteEmpty,
    SqliteSchema,
    SqliteTooBig,
    SqliteConstraint,
    SqliteMismatch,
    SqliteMisuse,
    SqliteNoLFS,
    SqliteAuth,
    SqliteRange,
    SqliteNotADatabase,
};

/// Maps a sqlite3 result code to our error set.
/// The else branch is unreachable because SQLite documents every
/// return code it can produce, but we guard against surprises.
fn map_error(rc: c_int) Error {
    return switch (rc) {
        c.SQLITE_ERROR      => error.SqliteError,
        c.SQLITE_INTERNAL   => error.SqliteInternal,
        c.SQLITE_PERM       => error.SqlitePerm,
        c.SQLITE_ABORT      => error.SqliteAbort,
        c.SQLITE_BUSY       => error.SqliteBusy,
        c.SQLITE_LOCKED     => error.SqliteLocked,
        c.SQLITE_NOMEM      => error.SqliteNoMem,
        c.SQLITE_READONLY   => error.SqliteReadOnly,
        c.SQLITE_INTERRUPT  => error.SqliteInterrupt,
        c.SQLITE_IOERR      => error.SqliteIOErr,
        c.SQLITE_CORRUPT    => error.SqliteCorrupt,
        c.SQLITE_NOTFOUND   => error.SqliteNotFound,
        c.SQLITE_FULL       => error.SqliteFull,
        c.SQLITE_CANTOPEN   => error.SqliteCantOpen,
        c.SQLITE_PROTOCOL   => error.SqliteProtocol,
        c.SQLITE_EMPTY      => error.SqliteEmpty,
        c.SQLITE_SCHEMA     => error.SqliteSchema,
        c.SQLITE_TOOBIG     => error.SqliteTooBig,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        c.SQLITE_MISMATCH   => error.SqliteMismatch,
        c.SQLITE_MISUSE     => error.SqliteMisuse,
        c.SQLITE_NOLFS      => error.SqliteNoLFS,
        c.SQLITE_AUTH       => error.SqliteAuth,
        c.SQLITE_RANGE      => error.SqliteRange,
        c.SQLITE_NOTADB     => error.SqliteNotADatabase,
        else                => error.SqliteError,
    };
}

/// Config controls how a database connection is opened.
/// Defaults to an in-memory read-only connection, which is safe
/// everywhere and lets us catch accidental writes in tests.
pub const Config = struct {
    path: ?[]const u8 = null,
    write: bool = false,
    create: bool = false,
};

/// Db wraps a single sqlite3 database connection.
/// It is not thread-safe; callers must provide their own serialisation.
pub const Db = struct {
    db: *c.sqlite3,

    /// Init opens or creates a database.
    /// When path is null an in-memory database is used.
    pub fn init(config: Config) !Db {
        var flags: c_int = c.SQLITE_OPEN_URI;
        if (config.write) {
            flags |= c.SQLITE_OPEN_READWRITE;
        } else {
            flags |= c.SQLITE_OPEN_READONLY;
        }
        if (config.create) flags |= c.SQLITE_OPEN_CREATE;

        // SQLite expects a null-terminated path. We copy into a fixed
        // buffer to guarantee the sentinel without heap allocation.
        var path_buf: [4096:0]u8 = undefined;
        const path_z: [:0]u8 = if (config.path) |p| blk: {
            assert(p.len < path_buf.len);
            @memcpy(path_buf[0..p.len], p);
            path_buf[p.len] = 0;
            break :blk path_buf[0..p.len :0];
        } else blk: {
            const memory = ":memory:";
            @memcpy(path_buf[0..memory.len], memory);
            path_buf[memory.len] = 0;
            break :blk path_buf[0..memory.len :0];
        };
        if (config.path == null) flags |= c.SQLITE_OPEN_MEMORY;

        var handle: ?*c.sqlite3 = undefined;
        const rc = c.sqlite3_open_v2(path_z.ptr, &handle, flags, null);
        if (rc != c.SQLITE_OK) {
            // We must not return without closing a partially-opened
            // handle because sqlite may have allocated resources.
            if (handle) |h| _ = c.sqlite3_close(h);
            return map_error(rc);
        }
        assert(handle != null);
        return .{ .db = handle.? };
    }

    /// Deinit closes the connection. All unprepared statements must
    /// have been finalized first; this is not checked.
    pub fn deinit(self: *Db) void {
        const rc = c.sqlite3_close(self.db);
        assert(rc == c.SQLITE_OK);
    }

    /// --- Comptime query helpers ----------------------------------------
    /// These functions accept a comptime query string. The string is
    /// forwarded directly to sqlite3_prepare_v3 without any pre-
    /// processing; the argument count is NOT checked at compile time.

    pub fn exec(
        self: *Db,
        comptime query: []const u8,
        args: anytype,
    ) !void {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);
        try stmt.step_done();
    }

    pub fn one(
        self: *Db,
        comptime T: type,
        comptime query: []const u8,
        args: anytype,
    ) !?T {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);
        return stmt.one(T);
    }

    pub fn one_alloc(
        self: *Db,
        comptime T: type,
        allocator: std.mem.Allocator,
        comptime query: []const u8,
        args: anytype,
    ) !?T {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);
        return stmt.one_alloc(T, allocator);
    }

    pub fn all(
        self: *Db,
        comptime T: type,
        allocator: std.mem.Allocator,
        comptime query: []const u8,
        args: anytype,
    ) ![]T {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);

        var list = std.ArrayList(T).init(allocator);
        errdefer list.deinit();
        while (try stmt.one_alloc(T, allocator)) |row| {
            try list.append(row);
        }
        return list.toOwnedSlice();
    }

    pub fn iterator(
        self: *Db,
        comptime T: type,
        comptime query: []const u8,
        args: anytype,
    ) !Iterator(T) {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        errdefer stmt.deinit();
        try stmt.bind(args);
        return Iterator(T){
            .db   = self.db,
            .stmt = stmt.stmt,
            .owns = true,
        };
    }

    /// --- Runtime query helpers -----------------------------------------
    /// These functions accept a runtime query string and are otherwise
    /// identical to their comptime counterparts.

    pub fn exec_args(
        self: *Db,
        query: []const u8,
        args: anytype,
    ) !void {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);
        try stmt.step_done();
    }

    pub fn one_args(
        self: *Db,
        comptime T: type,
        query: []const u8,
        args: anytype,
    ) !?T {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);
        return stmt.one(T);
    }

    pub fn one_args_alloc(
        self: *Db,
        comptime T: type,
        allocator: std.mem.Allocator,
        query: []const u8,
        args: anytype,
    ) !?T {
        var stmt = try PreparedStmt.prepare(self, query.ptr, query.len);
        defer stmt.deinit();
        try stmt.bind(args);
        return stmt.one_alloc(T, allocator);
    }

    /// --- Utility -------------------------------------------------------

    pub fn exec_multi(self: *Db, query: []const u8) !void {
        var tail: [*c]const u8 = query.ptr;
        while (true) {
            const chunk = std.mem.span(tail);
            if (chunk.len == 0) return;

            var handle: ?*c.sqlite3_stmt = undefined;
            const rc = c.sqlite3_prepare_v3(
                self.db, tail, @intCast(chunk.len), 0, &handle, &tail,
            );
            if (rc != c.SQLITE_OK) return map_error(rc);

            if (handle) |s| {
                defer _ = c.sqlite3_finalize(s);
                const step_rc = c.sqlite3_step(s);
                if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                    return map_error(step_rc);
                }
            }
        }
    }

    pub fn last_insert_row_id(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes(self.db);
    }
};

// -----------------------------------------------------------------------
// PreparedStmt
//
// Internal wrapper around sqlite3_stmt. Each instance is used for
// exactly one query execution and must not outlive the Db.
// -----------------------------------------------------------------------

const PreparedStmt = struct {
    db: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    fn prepare(db: *Db, sql: [*c]const u8, sql_len: usize) !PreparedStmt {
        var handle: ?*c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v3(
            db.db, sql, @intCast(sql_len), 0, &handle, null,
        );
        if (rc != c.SQLITE_OK) return map_error(rc);
        assert(handle != null);
        return .{ .db = db.db, .stmt = handle.? };
    }

    fn deinit(self: *PreparedStmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    fn bind(self: *PreparedStmt, args: anytype) !void {
        const ArgsType = @TypeOf(args);
        switch (@typeInfo(ArgsType)) {
            .@"struct" => |info| {
                inline for (info.fields, 0..) |field, i| {
                    try bind_value(
                        self.stmt, @intCast(i + 1), @field(args, field.name),
                    );
                }
            },
            .pointer => |ptr| if (ptr.size == .slice) {
                for (args, 0..) |val, i| {
                    try bind_value(self.stmt, @intCast(i + 1), val);
                }
            } else {
                @compileError("cannot bind pointer type " ++ @typeName(ArgsType));
            },
            .array => {
                for (args, 0..) |val, i| {
                    try bind_value(self.stmt, @intCast(i + 1), val);
                }
            },
            else => @compileError("cannot bind type " ++ @typeName(ArgsType)),
        }
    }

    /// StepDone steps through a statement that is not expected to
    /// produce rows. Both DONE and ROW are treated as success because
    /// some statements (e.g. PRAGMA) return a row even when used for
    /// their side-effect.
    fn step_done(self: *PreparedStmt) !void {
        const rc = c.sqlite3_step(self.stmt);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
            return map_error(rc);
        }
    }

    /// One reads exactly one row, or null if the result set is empty.
    fn one(self: *PreparedStmt, comptime T: type) !?T {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return map_error(rc);
        const val = try read_column(self.stmt, T, 0, null);
        return val;
    }

    /// OneAlloc is like one but copies string/blob data with allocator.
    fn one_alloc(
        self: *PreparedStmt,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) !?T {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return map_error(rc);
        const val = try read_column(self.stmt, T, 0, allocator);
        return val;
    }
};

// -----------------------------------------------------------------------
// Iterator
//
// Iterates over a result set one row at a time. The iterator owns the
// underlying prepared statement and finalises it on deinit.
// -----------------------------------------------------------------------

pub fn Iterator(comptime T: type) type {
    return struct {
        db:   *c.sqlite3,
        stmt: *c.sqlite3_stmt,
        owns: bool = false,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (self.owns) _ = c.sqlite3_finalize(self.stmt);
        }

        pub fn next(self: *Self) !?T {
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_DONE) return null;
            if (rc != c.SQLITE_ROW) return map_error(rc);
            return read_column(self.stmt, T, 0, null);
        }

        pub fn next_alloc(self: *Self, allocator: std.mem.Allocator) !?T {
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_DONE) return null;
            if (rc != c.SQLITE_ROW) return map_error(rc);
            return read_column(self.stmt, T, 0, allocator);
        }
    };
}

// -----------------------------------------------------------------------
// Binding — maps Zig values to SQLite bind parameters.
// -----------------------------------------------------------------------

fn bind_value(stmt: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const rc = c.sqlite3_bind_int64(stmt, index, @intCast(value));
            if (rc != c.SQLITE_OK) return map_error(rc);
        },
        .float, .comptime_float => {
            const rc = c.sqlite3_bind_double(stmt, index, @floatCast(value));
            if (rc != c.SQLITE_OK) return map_error(rc);
        },
        .bool => {
            const rc = c.sqlite3_bind_int64(
                stmt, index, @intFromBool(value),
            );
            if (rc != c.SQLITE_OK) return map_error(rc);
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => switch (ptr.child) {
                u8 => {
                    const rc = c.sqlite3_bind_text64(
                        stmt, index, value.ptr, @intCast(value.len),
                        c.SQLITE_TRANSIENT, c.SQLITE_UTF8,
                    );
                    if (rc != c.SQLITE_OK) return map_error(rc);
                },
                else => @compileError(
                    "cannot bind slice of " ++ @typeName(ptr.child),
                ),
            },
            .one   => try bind_value(stmt, index, value.*),
            else   => @compileError(
                "cannot bind type " ++ @typeName(T),
            ),
        },
        .optional => if (value) |v| {
            try bind_value(stmt, index, v);
        } else {
            const rc = c.sqlite3_bind_null(stmt, index);
            if (rc != c.SQLITE_OK) return map_error(rc);
        },
        .@"enum" => try bind_value(stmt, index, @intFromEnum(value)),
        else => @compileError("cannot bind type " ++ @typeName(T)),
    }
}

// -----------------------------------------------------------------------
// Reading — maps SQLite column values to Zig types.
// Every public read path converges on read_column, which dispatches by
// the target Zig type.  This keeps control flow centralised: one
// function owns all the branching, and leaf helpers are pure.
// -----------------------------------------------------------------------

fn read_column(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
    allocator: ?std.mem.Allocator,
) !T {
    switch (@typeInfo(T)) {
        .int       => return read_int(stmt, T, col),
        .float     => return read_float(stmt, T, col),
        .bool      => return read_bool(stmt, col),
        .void      => return,
        .pointer   => return read_pointer(stmt, T, col, allocator),
        .array     => return read_array(stmt, T, col),
        .optional  => return read_optional(stmt, T, col, allocator),
        .@"struct" => return read_struct(stmt, T, allocator),
        .@"enum"   => return read_enum(stmt, T, col),
        else       => @compileError("cannot read type " ++ @typeName(T)),
    }
}

fn read_int(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
) T {
    return @intCast(c.sqlite3_column_int64(stmt, col));
}

fn read_float(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
) T {
    return @floatCast(c.sqlite3_column_double(stmt, col));
}

fn read_bool(stmt: *c.sqlite3_stmt, col: c_int) bool {
    return c.sqlite3_column_int64(stmt, col) > 0;
}

fn read_pointer(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
    allocator: ?std.mem.Allocator,
) !T {
    const ptr_info = @typeInfo(T).pointer;
    if (ptr_info.size != .slice or ptr_info.child != u8) {
        @compileError("cannot read pointer type " ++ @typeName(T));
    }

    // sqlite3_column_text returns a pointer to internal storage
    // that remains valid until the next sqlite3_step call. Since we
    // may finalise the statement after this read, we must copy when
    // the caller provided an allocator.
    const data = c.sqlite3_column_text(stmt, col);
    const len  = c.sqlite3_column_bytes(stmt, col);
    if (data == null or len == 0) {
        if (allocator) |a| return a.dupe(u8, "");
        return @as([]const u8, "");
    }
    const slice = @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
    if (allocator) |a| return a.dupe(u8, slice);
    return slice;
}

fn read_array(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
) !T {
    const arr_info = @typeInfo(T).array;
    if (arr_info.child != u8) {
        @compileError("cannot read array of " ++ @typeName(arr_info.child));
    }

    const data = c.sqlite3_column_text(stmt, col);
    const len  = c.sqlite3_column_bytes(stmt, col);
    if (data == null or len == 0) {
        if (arr_info.sentinel) |s| {
            var buf: T = undefined;
            @memset(&buf, s);
            return buf;
        }
        return @as(T, undefined);
    }
    const slice  = @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
    var buf: T = undefined;
    const copy_len = @min(slice.len, buf.len);
    @memcpy(buf[0..copy_len], slice[0..copy_len]);
    return buf;
}

fn read_optional(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
    allocator: ?std.mem.Allocator,
) !T {
    const col_type = c.sqlite3_column_type(stmt, col);
    if (col_type == c.SQLITE_NULL) return null;
    return read_column(stmt, @typeInfo(T).optional.child, col, allocator);
}

fn read_struct(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    allocator: ?std.mem.Allocator,
) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        @field(result, field.name) = try read_column(
            stmt, field.type, @intCast(i), allocator,
        );
    }
    return result;
}

fn read_enum(
    stmt: *c.sqlite3_stmt,
    comptime T: type,
    col: c_int,
) T {
    const enum_info = @typeInfo(T).@"enum";
    return @enumFromInt(
        @as(enum_info.tag_type, @intCast(c.sqlite3_column_int64(stmt, col))),
    );
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "init and close memory db" {
    var db = try Db.init(.{});
    defer db.deinit();
}

test "exec and one" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, 'hello')", .{});
    try db.exec("INSERT INTO t VALUES (2, 'world')", .{});

    const val = try db.one(
        i64, "SELECT id FROM t WHERE name = 'hello'", .{},
    );
    try std.testing.expectEqual(@as(i64, 1), val.?);
}

test "one with args" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, 'hello')", .{});

    const val = try db.one(
        i64, "SELECT id FROM t WHERE name = ?", .{"hello"},
    );
    try std.testing.expectEqual(@as(i64, 1), val.?);
}

test "one with struct args" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, 'hello')", .{});

    const val = try db.one(
        i64, "SELECT id FROM t WHERE name = $name", .{.name = "hello"},
    );
    try std.testing.expectEqual(@as(i64, 1), val.?);
}

test "one struct row" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, 'hello')", .{});

    const Row = struct { id: i64, name: []const u8 };
    const row = try db.one_alloc(
        Row, std.testing.allocator,
        "SELECT id, name FROM t WHERE id = ?", .{@as(i64, 1)},
    );
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 1), row.?.id);
    try std.testing.expectEqualStrings("hello", row.?.name);
}

test "all" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, 'a')", .{});
    try db.exec("INSERT INTO t VALUES (2, 'b')", .{});

    const Row   = struct { id: i64, name: []const u8 };
    const rows  = try db.all(
        Row, std.testing.allocator,
        "SELECT id, name FROM t ORDER BY id", .{},
    );
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].id);
    try std.testing.expectEqualStrings("a", rows[0].name);
}

test "exec_multi" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec_multi(
        "CREATE TABLE a (b INT); CREATE TABLE c (d INT);",
    );
    const val = try db.one(
        i64,
        "SELECT count(*) FROM sqlite_master WHERE type = 'table'",
        .{},
    );
    try std.testing.expectEqual(@as(i64, 3), val.?);
}

test "iterator" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, 'a')", .{});
    try db.exec("INSERT INTO t VALUES (2, 'b')", .{});

    const Row  = struct { id: i64, name: []const u8 };
    var iter   = try db.iterator(
        Row, "SELECT id, name FROM t ORDER BY id", .{},
    );
    defer iter.deinit();

    const r1 = try iter.next_alloc(std.testing.allocator);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqual(@as(i64, 1), r1.?.id);
    try std.testing.expectEqualStrings("a", r1.?.name);

    const r2 = try iter.next_alloc(std.testing.allocator);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqual(@as(i64, 2), r2.?.id);
    try std.testing.expectEqualStrings("b", r2.?.name);

    const r3 = try iter.next_alloc(std.testing.allocator);
    try std.testing.expect(r3 == null);
}

test "last_insert_row_id and changes" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (NULL, 'hello')", .{});

    try std.testing.expectEqual(@as(i64, 1), db.last_insert_row_id());
    try std.testing.expectEqual(@as(i64, 1), db.changes());
}

test "null binding" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t VALUES (1, ?)", .{@as(?[]const u8, null)});

    const val = try db.one(
        ?[]const u8, "SELECT name FROM t WHERE id = 1", .{},
    );
    try std.testing.expect(val == null);
}

test "read null optional" {
    var db = try Db.init(.{});
    defer db.deinit();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});
    try db.exec("INSERT INTO t (id) VALUES (1)", .{});

    const val = try db.one_alloc(
        ?[]const u8, std.testing.allocator,
        "SELECT name FROM t WHERE id = 1", .{},
    );
    try std.testing.expect(val == null);
}
