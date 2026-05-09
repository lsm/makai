const std = @import("std");

pub const File = std.fs.File;
pub const FileReader = std.fs.File.Reader;
pub const FileWriter = std.fs.File.Writer;

pub const default_buffer_size = 4096;

var stdin_reader_buffer: [default_buffer_size]u8 = undefined;
var stdout_writer_buffer: [default_buffer_size]u8 = undefined;

/// Return the process stdin file handle.
///
/// Zig 0.16 mapping: this will borrow stdin from the Makai default I/O context
/// or test context, preserving public APIs that avoid raw `std.Io`.
pub fn stdin() File {
    return std.fs.File.stdin();
}

/// Return the process stdout file handle.
///
/// Zig 0.16 mapping: this will borrow stdout from the Makai default I/O context
/// or test context, preserving public APIs that avoid raw `std.Io`.
pub fn stdout() File {
    return std.fs.File.stdout();
}

/// Return a Zig 0.15.2 stdin reader without exposing `std.Io` in the public API.
///
/// The returned reader borrows a module-level buffer, matching the process-global
/// nature of stdin. Future stdio transport call-site migration can use
/// `fileReader` with caller-owned buffers for testable file-backed readers.
///
/// Zig 0.16 mapping: adapt this helper to the selected Makai input context while
/// preserving caller ownership: stdin itself is borrowed and not closed here.
pub fn getStdinReader() FileReader {
    return stdin().reader(&stdin_reader_buffer);
}

/// Return a Zig 0.15.2 stdout writer without exposing `std.Io` in the public API.
///
/// The returned writer borrows a module-level buffer. Callers that write through
/// it are responsible for flushing according to `std.fs.File.Writer` semantics.
pub fn getStdoutWriter() FileWriter {
    return stdout().writer(&stdout_writer_buffer);
}

/// Return a reader for an explicit file handle using a caller-owned buffer.
///
/// Used by future stdio transport and CLI migrations to centralize file reader
/// construction while keeping `std.Io` out of public signatures.
pub fn fileReader(file: File, buffer: []u8) FileReader {
    return file.reader(buffer);
}

/// Return a writer for an explicit file handle using a caller-owned buffer.
///
/// Used by future stdio transport and CLI migrations to centralize file writer
/// construction while keeping `std.Io` out of public signatures.
pub fn fileWriter(file: File, buffer: []u8) FileWriter {
    return file.writer(buffer);
}

test "compat stdio helpers construct file handles readers and writers" {
    const in = stdin();
    const out = stdout();
    var reader = getStdinReader();
    var writer = getStdoutWriter();
    var explicit_reader_buf: [default_buffer_size]u8 = undefined;
    var explicit_writer_buf: [default_buffer_size]u8 = undefined;
    var explicit_reader = fileReader(in, &explicit_reader_buf);
    var explicit_writer = fileWriter(out, &explicit_writer_buf);

    _ = &reader;
    _ = &writer;
    _ = &explicit_reader;
    _ = &explicit_writer;
}
