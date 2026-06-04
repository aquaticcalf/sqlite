const std = @import("std");
const assert = std.debug.assert;
const conn = @import("conn.zig");
const Db = conn.Db;

/// Table creates a compile-time table descriptor from a name and row type.
/// The table_name is used in SQL generation; Row is the Zig struct whose
/// fields correspond one-to-one with table columns, by position.
///
/// Callers typically assign the result to a named constant:
///
///     const users = table("users", struct {
///         id:        []const u8,
///         handle:    []const u8,
///         ...
///     });
///
/// This lets db.insert infer both the table name and the column names
/// from a single source.
pub fn table(comptime name: []const u8, comptime RowType: type) type {
    assert(name.len > 0);

    return struct {
        pub const table_name = name;
        pub const Row = RowType;
    };
}

/// InsertStmt generates a parameterised INSERT statement at compile time.
/// The output is something like:
///
///     INSERT INTO users (id, handle) VALUES (?, ?)
///
/// The columns are derived from the field names of the struct type
/// passed as ValuesType.
pub fn insert_stmt(comptime TableMeta: type, comptime ValuesType: type) []const u8 {
    const field_info = @typeInfo(ValuesType).@"struct".fields;
    assert(field_info.len > 0);

    // The maximum statement we can produce is bounded by the concatenation
    // of: "INSERT INTO ", table_name, " (", comma-separated field names,
    // ") VALUES (", comma-separated "?", ")".
    // 2000 bytes is generous for any real-world table.
    var buf: [2000]u8 = undefined;
    var pos: u32 = 0;

    // Build the opening clause.
    const header = "INSERT INTO ";
    @memcpy(buf[0..header.len], header);
    pos += @intCast(header.len);

    @memcpy(buf[pos..], TableMeta.table_name);
    pos += @intCast(TableMeta.table_name.len);
    buf[pos] = ' ';
    pos += 1;
    buf[pos] = '(';
    pos += 1;

    // Emit column names separated by commas.
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

    // Close the column list and open the value list.
    const middle = ") VALUES (";
    @memcpy(buf[pos..], middle);
    pos += @intCast(middle.len);

    // One bind marker per field.
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

/// Insert is a convenience wrapper around insert_stmt and db.execArgs.
/// It builds the INSERT statement at compile time and executes it
/// immediately.
pub fn insert(db: *Db, comptime TableMeta: type, values: anytype) !void {
    const sql = comptime insert_stmt(TableMeta, @TypeOf(values));
    try db.execArgs(sql, values);
}
