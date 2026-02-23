import assert from "node:assert/strict";
import test from "node:test";
import {
  ModelRefParseError,
  type ModelRefParseErrorCode,
  parseModelRef,
} from "../src/diagnostics/model_ref";

test("parseModelRef parses canonical refs with reserved chars and UTF-8 model IDs", () => {
  const reserved = parseModelRef("anthropic/anthropic-messages@claude%3Asonnet%2F4%40latest%3Fx%3D1%26y%3D2");
  assert.equal(reserved.providerId, "anthropic");
  assert.equal(reserved.api, "anthropic-messages");
  assert.equal(reserved.modelId, "claude:sonnet/4@latest?x=1&y=2");

  const utf8 = parseModelRef("openai/openai-responses@%E6%A8%A1%E5%9E%8B%3A%C3%9F%F0%9F%9A%80");
  assert.equal(utf8.providerId, "openai");
  assert.equal(utf8.api, "openai-responses");
  assert.equal(utf8.modelId, "模型:ß🚀");
});

test("parseModelRef rejects malformed refs with Zig-matching error categories", () => {
  expectParseError("/api@model", "missing_provider_id");
  expectParseError("provider/@model", "missing_api");
  expectParseError("provider/api@", "missing_model_id");
  expectParseError("provider-api-model", "missing_separators");
  expectParseError("provider/api@bad%2", "invalid_percent_escape");
  expectParseError("provider/api@bad%GG", "invalid_percent_escape");
  expectParseError("provider/api/v1@model", "ambiguous_separators");
  expectParseError("provider/api@bad/model", "ambiguous_separators");
  expectParseError("provider/api@bad@model", "ambiguous_separators");
  expectParseError("pro%vider/api@model", "invalid_provider_id");
  expectParseError("provider/ap%i@model", "invalid_api");
  expectParseError("provider/api@bad name", "invalid_model_id_encoding");
});

function expectParseError(modelRef: string, expectedCode: ModelRefParseErrorCode): void {
  assert.throws(
    () => parseModelRef(modelRef),
    (error: unknown) => error instanceof ModelRefParseError && error.code === expectedCode,
  );
}
