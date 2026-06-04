# sqlite - a Drizzle-like Zig wrapper for libsqlite3

A minimal, ergonomic Zig wrapper around the system `libsqlite3` with a
Drizzle-inspired API.  No code generation, no build-time C compilation,
no bundled amalgamation - just a thin layer over the C API.

## API Overview

### Connecting

```zig
const sqlite = @import("sqlite");

var db = try sqlite.Db.init(.{
    .path   = "my.db",  // null → in-memory
    .write  = true,      // open for writing
    .create = true,      // create if missing
});
defer db.deinit();
```

`Config` fields all have safe defaults - an in-memory read-only connection,
so you can't accidentally corrupt a real database.

### Executing statements

```zig
// Comptime query + no arguments
try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", .{});

// Comptime query + tuple arguments (positional ?)
try db.exec("INSERT INTO t VALUES (?, ?)", .{ 1, "hello" });

// Comptime query + struct arguments (named $field)
try db.exec("INSERT INTO t VALUES ($id, $name)", .{ .id = 1, .name = "hello" });

// Runtime query (no comptime required)
try db.exec_args("PRAGMA synchronous = NORMAL", .{});

// Multiple semicolon-separated statements
try db.exec_multi("CREATE TABLE a (b INT); CREATE TABLE c (d INT);");
```

### Reading rows

```zig
// Scalar: one(T, query, args)
const count = try db.one(usize, "SELECT count(*) FROM t", .{});

// Scalar with heap-allocated data
const name = try db.one_alloc(?[]const u8, allocator,
    "SELECT name FROM t WHERE id = ?", .{1});

// Struct row (field order = column order)
const Row = struct { id: i64, name: []const u8 };
const row = try db.one_alloc(Row, allocator,
    "SELECT id, name FROM t WHERE id = ?", .{@as(i64, 1)});

// All rows
const rows = try db.all(Row, allocator,
    "SELECT id, name FROM t ORDER BY id", .{});
defer allocator.free(rows);
```

Runtime-query variants are also available:
- `one_args(T, query, args)`
- `one_args_alloc(T, allocator, query, args)`

#### Iterator

```zig
var iter = try db.iterator(Row, "SELECT id, name FROM t ORDER BY id", .{});
defer iter.deinit();

while (try iter.next_alloc(allocator)) |row| {
    // row.id, row.name
}
```

### Utility

```zig
const last_id = db.last_insert_row_id();
const n_changed = db.changes();  // i64
```

### Schema helpers (Drizzle-like)

```zig
const users = sqlite.table("users", struct {
    id:     []const u8,
    handle: []const u8,
    email:  ?[]const u8,
});

// Generates: INSERT INTO users (id, handle, email) VALUES (?, ?, ?)
const stmt = sqlite.insert_stmt(users, struct {
    id:     []const u8,
    handle: []const u8,
    email:  ?[]const u8,
});

// Builds and executes the INSERT in one call
try sqlite.insert(&db, users, .{
    .id     = "usr_123",
    .handle = "alice",
    .email  = null,
});
```

### Type mapping

| Zig type                | SQLite column type |
|-------------------------|--------------------|
| `i64`, `u64`, `i32` …   | INTEGER            |
| `f64`, `f32`            | REAL               |
| `bool`                  | INTEGER (0/1)      |
| `[]const u8`            | TEXT               |
| `[N:0]u8`              | TEXT               |
| `?T`                    | any (nullable)     |
| `struct { … }`          | multiple columns   |
| `enum`                  | INTEGER (tag)      |

### Error handling

The `Error` set maps every documented `sqlite3_*` return code to a
distinct Zig error so callers can react to specific failures
(e.g. `error.SqliteConstraint` vs `error.SqliteBusy`).

## License

MIT - see [LICENSE](LICENSE).
