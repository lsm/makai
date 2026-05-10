const std = @import("std");

pub const File = std.fs.File;
pub const FileReader = std.fs.File.Reader;
pub const FileWriter = std.fs.File.Writer;

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

/// Return a Zig 0.15.2 stdin reader using caller-owned buffer storage.
///
/// The reader is initialized in streaming mode so repeated helper construction
/// continues from the file descriptor's current position instead of resetting to
/// offset 0 when stdin is redirected from a seekable file.
///
/// Zig 0.16 mapping: adapt this helper to the selected Makai input context while
/// preserving buffer ownership: callers provide the storage and stdin itself is
/// borrowed, not closed here.
pub fn getStdinReader(buffer: []u8) FileReader {
    return stdin().readerStreaming(buffer);
}

/// Return a Zig 0.15.2 stdout writer using caller-owned buffer storage.
///
/// The writer is initialized in streaming mode so repeated helper construction
/// appends through the file descriptor's current position instead of resetting to
/// offset 0 when stdout is redirected to a seekable file. Callers that write
/// through it are responsible for flushing according to `std.fs.File.Writer`
/// semantics.
pub fn getStdoutWriter(buffer: []u8) FileWriter {
    return stdout().writerStreaming(buffer);
}

/// Return a streaming reader for an explicit file handle using a caller-owned
/// buffer.
///
/// Used by future stdio transport and CLI migrations to centralize file reader
/// construction while keeping `std.Io` out of public signatures.
pub fn fileReader(file: File, buffer: []u8) FileReader {
    return file.readerStreaming(buffer);
}

/// Return a streaming writer for an explicit file handle using a caller-owned
/// buffer.
///
/// Used by future stdio transport and CLI migrations to centralize file writer
/// construction while keeping `std.Io` out of public signatures.
pub fn fileWriter(file: File, buffer: []u8) FileWriter {
    return file.writerStreaming(buffer);
}

test "compat stdio helpers construct file handles readers and writers" {
    const in = stdin();
    const out = stdout();
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var explicit_reader_buf: [4096]u8 = undefined;
    var explicit_writer_buf: [4096]u8 = undefined;

    var reader = getStdinReader(&stdin_buf);
    var writer = getStdoutWriter(&stdout_buf);
    var explicit_reader = fileReader(in, &explicit_reader_buf);
    var explicit_writer = fileWriter(out, &explicit_writer_buf);

    _ = &reader;
    _ = &writer;
    _ = &explicit_reader;
    _ = &explicit_writer;
}
