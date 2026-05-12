import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Shared binary resolver options. */
type BinaryResolverBaseOptions = {
  cacheDir?: string;
};

/** Resolve Makai from an explicit filesystem path. */
type BinaryPathResolverOptions = BinaryResolverBaseOptions & {
  type?: "path";
  binaryPath: string;
  binaryUrl?: undefined;
  checksumSha256?: string;
};

/** Download Makai from a URL and verify it with a required SHA-256 checksum. */
type BinaryUrlResolverOptions = BinaryResolverBaseOptions & {
  type?: "url";
  binaryPath?: undefined;
  binaryUrl: string;
  checksumSha256: string;
};

/** Resolve Makai automatically from local build outputs or the system PATH. */
type BinaryAutoResolverOptions = BinaryResolverBaseOptions & {
  type?: "auto";
  binaryPath?: undefined;
  binaryUrl?: undefined;
  checksumSha256?: string;
};

/**
 * Strategy options for locating the `makai` executable used by stdio clients.
 *
 * Use `binaryPath` for an existing local binary, `binaryUrl` plus
 * `checksumSha256` for a verified download, or omit both for automatic lookup.
 */
export type BinaryResolverOptions =
  | BinaryPathResolverOptions
  | BinaryUrlResolverOptions
  | BinaryAutoResolverOptions;

const ENV_BINARY_PATH = "MAKAI_BINARY_PATH";
const ENV_BINARY_URL = "MAKAI_BINARY_URL";
const ENV_BINARY_SHA256 = "MAKAI_BINARY_SHA256";

function binaryNameForPlatform(platform = process.platform): string {
  return platform === "win32" ? "makai.exe" : "makai";
}

async function ensureFileExists(filePath: string): Promise<void> {
  await fs.access(filePath);
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch (error: unknown) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

function sha256(content: Buffer): string {
  return createHash("sha256").update(content).digest("hex");
}

function requireChecksumForUrl(binaryUrl: string, checksumSha256: string | undefined): string {
  if (!checksumSha256) {
    throw new Error(`SHA256 checksum is required when downloading makai binary from URL: ${binaryUrl}`);
  }
  return checksumSha256;
}

async function verifyChecksum(filePath: string, checksumSha256: string): Promise<void> {
  const content = await fs.readFile(filePath);
  const actual = sha256(content);
  if (actual !== checksumSha256.toLowerCase()) {
    throw new Error(`binary checksum mismatch: expected ${checksumSha256}, got ${actual}`);
  }
}

async function downloadToCache(url: string, targetPath: string, checksumSha256: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`failed to download binary: ${response.status} ${response.statusText}`);
  }
  const arrayBuffer = await response.arrayBuffer();
  const content = Buffer.from(arrayBuffer);

  const actual = sha256(content);
  if (actual !== checksumSha256.toLowerCase()) {
    throw new Error(`binary checksum mismatch: expected ${checksumSha256}, got ${actual}`);
  }

  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  const tempPath = `${targetPath}.tmp`;
  await fs.writeFile(tempPath, content);
  if (process.platform !== "win32") {
    await fs.chmod(tempPath, 0o755);
  }
  await fs.rename(tempPath, targetPath);
}

/**
 * Resolves the Makai executable path according to environment variables and options.
 *
 * Environment variables take precedence over options: `MAKAI_BINARY_PATH`,
 * `MAKAI_BINARY_URL`, and `MAKAI_BINARY_SHA256`.
 *
 * @param options Resolver strategy and cache directory options.
 * @returns Absolute path to a local binary, or `"makai"` to use PATH lookup.
 * @throws If an explicit binary is missing, download fails, or checksum verification fails.
 */
export async function resolveMakaiBinary(options: BinaryResolverOptions = {}): Promise<string> {
  const explicitBinaryPath = process.env[ENV_BINARY_PATH] ?? options.binaryPath;
  if (explicitBinaryPath) {
    const resolved = path.resolve(explicitBinaryPath);
    await ensureFileExists(resolved);
    return resolved;
  }

  const binaryUrl = process.env[ENV_BINARY_URL] ?? options.binaryUrl;
  const checksumSha256 = process.env[ENV_BINARY_SHA256] ?? options.checksumSha256;
  if (binaryUrl) {
    const requiredChecksumSha256 = requireChecksumForUrl(binaryUrl, checksumSha256);
    const binaryName = binaryNameForPlatform();
    const cacheDir = options.cacheDir ?? path.join(os.homedir(), ".cache", "makai", "bin");
    const urlPathName = new URL(binaryUrl).pathname;
    const fileName = path.basename(urlPathName) || binaryName;
    const cachePath = path.join(cacheDir, fileName);

    if (await fileExists(cachePath)) {
      try {
        await verifyChecksum(cachePath, requiredChecksumSha256);
        return cachePath;
      } catch (error: unknown) {
        if (error instanceof Error && error.message.startsWith("binary checksum mismatch")) {
          await fs.rm(cachePath, { force: true });
        } else {
          throw error;
        }
      }
    }

    if (!(await fileExists(cachePath))) {
      await downloadToCache(binaryUrl, cachePath, requiredChecksumSha256);
      return cachePath;
    }

    return cachePath;
  }

  const binaryName = binaryNameForPlatform();
  const localCandidates = [
    path.resolve(process.cwd(), "zig-out", "bin", binaryName),
    path.resolve(process.cwd(), "zig", "zig-out", "bin", binaryName),
  ];
  for (const candidate of localCandidates) {
    if (await fileExists(candidate)) {
      return candidate;
    }
  }

  return "makai";
}
