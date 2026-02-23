export type ModelRefParseErrorCode =
  | "missing_provider_id"
  | "missing_api"
  | "missing_model_id"
  | "missing_separators"
  | "ambiguous_separators"
  | "invalid_provider_id"
  | "invalid_api"
  | "invalid_percent_escape"
  | "invalid_model_id_encoding"
  | "invalid_utf8_model_id";

export class ModelRefParseError extends Error {
  constructor(
    message: string,
    public readonly code: ModelRefParseErrorCode,
  ) {
    super(message);
    this.name = "ModelRefParseError";
  }
}

export type ParsedModelRef = {
  providerId: string;
  api: string;
  modelId: string;
};

// Intentionally parser-only for diagnostics per spec §3.1; formatter remains server-side canonicalization.
export function parseModelRef(modelRef: string): ParsedModelRef {
  const slashIndex = modelRef.indexOf("/");
  if (slashIndex === -1) {
    throw new ModelRefParseError("model_ref is missing '/' and '@' separators", "missing_separators");
  }
  if (slashIndex === 0) {
    throw new ModelRefParseError("model_ref is missing provider_id segment", "missing_provider_id");
  }

  const firstAtIndex = modelRef.indexOf("@");
  if (firstAtIndex !== -1 && firstAtIndex < slashIndex) {
    throw new ModelRefParseError("model_ref contains ambiguous separators in provider_id", "ambiguous_separators");
  }

  const atOffset = modelRef.slice(slashIndex + 1).indexOf("@");
  if (atOffset === -1) {
    throw new ModelRefParseError("model_ref is missing '@' separator", "missing_separators");
  }
  const atIndex = slashIndex + 1 + atOffset;

  const extraSlashInApi = modelRef.slice(slashIndex + 1, atIndex).indexOf("/");
  if (extraSlashInApi !== -1) {
    throw new ModelRefParseError("model_ref contains ambiguous '/' separators", "ambiguous_separators");
  }
  if (modelRef.slice(atIndex + 1).includes("@")) {
    throw new ModelRefParseError("model_ref contains ambiguous '@' separators", "ambiguous_separators");
  }
  if (modelRef.slice(atIndex + 1).includes("/")) {
    throw new ModelRefParseError("model_ref contains ambiguous '/' separators", "ambiguous_separators");
  }

  const providerId = modelRef.slice(0, slashIndex);
  const api = modelRef.slice(slashIndex + 1, atIndex);
  const encodedModelId = modelRef.slice(atIndex + 1);

  validateProviderId(providerId);
  validateApi(api);

  if (encodedModelId.length === 0) {
    throw new ModelRefParseError("model_ref is missing model_id segment", "missing_model_id");
  }

  validateEncodedModelId(encodedModelId);

  try {
    const modelId = decodeURIComponent(encodedModelId);
    return { providerId, api, modelId };
  } catch {
    throw new ModelRefParseError("model_ref model_id is not valid UTF-8 percent encoding", "invalid_utf8_model_id");
  }
}

function validateProviderId(providerId: string): void {
  if (providerId.length === 0) {
    throw new ModelRefParseError("model_ref is missing provider_id segment", "missing_provider_id");
  }
  if (hasForbiddenSegmentChar(providerId)) {
    throw new ModelRefParseError("provider_id contains forbidden characters", "invalid_provider_id");
  }
}

function validateApi(api: string): void {
  if (api.length === 0) {
    throw new ModelRefParseError("model_ref is missing api segment", "missing_api");
  }
  if (hasForbiddenSegmentChar(api)) {
    throw new ModelRefParseError("api contains forbidden characters", "invalid_api");
  }
}

function hasForbiddenSegmentChar(value: string): boolean {
  return value.includes("/") || value.includes("@") || value.includes("%");
}

function validateEncodedModelId(encodedModelId: string): void {
  let index = 0;
  while (index < encodedModelId.length) {
    const char = encodedModelId[index];
    if (char === "%") {
      const hi = encodedModelId[index + 1];
      const lo = encodedModelId[index + 2];
      if (!hi || !lo || !isHex(hi) || !isHex(lo)) {
        throw new ModelRefParseError("model_id has invalid percent escape", "invalid_percent_escape");
      }
      index += 3;
      continue;
    }

    if (char === "/" || char === "@") {
      throw new ModelRefParseError("model_id contains ambiguous separators", "ambiguous_separators");
    }

    if (!isUnreserved(char)) {
      throw new ModelRefParseError("model_id has non-canonical unescaped characters", "invalid_model_id_encoding");
    }

    index += 1;
  }
}

function isHex(char: string): boolean {
  const code = char.charCodeAt(0);
  return (
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x46) ||
    (code >= 0x61 && code <= 0x66)
  );
}

function isUnreserved(char: string): boolean {
  if (char.length !== 1) return false;
  const code = char.charCodeAt(0);
  return (
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    (code >= 0x30 && code <= 0x39) ||
    char === "-" ||
    char === "." ||
    char === "_" ||
    char === "~"
  );
}
