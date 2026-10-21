import { boundedBody } from "../../../supabase/functions/_shared/request-body.ts";
import { backendOrigin } from "../../../supabase/functions/_shared/backend-origin.ts";

export const MAX_FILE_BYTES = 20 * 1024 * 1024;
export const MAX_REQUEST_BYTES = 28 * 1024 * 1024;
const MAX_TEXT_CHARACTERS = 120_000;
type Runtime = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
};
type FileInput = {
  file: string;
  fileName: string;
  fileType: string;
  forceOCR?: boolean;
  forceOcr?: boolean;
};

/** Optional legacy project-file contract. No provider, OCR, parser or storage access. */
export function createFileProcessor(runtime: Runtime) {
  return async (request: Request): Promise<Response> => {
    let fileName = "unknown",
      originalType = "unknown";
    const reply = (
      status: string,
      errorCode?: string,
      httpStatus = 200,
      extractedText?: string,
    ) =>
      Response.json(
        {
          status,
          ...(errorCode ? { errorCode } : {}),
          fileName,
          originalType,
          ...(extractedText !== undefined
            ? { extractedText, usedOcr: false }
            : {}),
        },
        {
          status: httpStatus,
          headers: {
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
          },
        },
      );
    if (request.method !== "POST")
      return reply("error", "method_not_allowed", 405);
    const bearer = request.headers.get("Authorization");
    if (!bearer || bearer.length > 8192 || !/^Bearer [^\s]+$/.test(bearer))
      return reply("error", "unauthorized", 401);
    const contentLength = request.headers.get("Content-Length");
    if (
      contentLength &&
      (!/^\d+$/.test(contentLength) ||
        Number(contentLength) > MAX_REQUEST_BYTES)
    )
      return reply("error", "file_too_large", 413);
    if (
      request.headers
        .get("Content-Type")
        ?.split(";")[0]
        .trim()
        .toLowerCase() !== "application/json"
    )
      return reply("error", "invalid_content_type", 415);

    let raw: string;
    try {
      raw = await boundedBody(request, MAX_REQUEST_BYTES);
    } catch (error) {
      return reply(
        "error",
        error instanceof Error && error.message === "request_too_large"
          ? "file_too_large"
          : "invalid_request",
        error instanceof Error && error.message === "request_too_large"
          ? 413
          : 400,
      );
    }
    let input: FileInput;
    try {
      const parsed: unknown = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
        throw Error();
      input = parsed as FileInput;
      if (
        typeof input.file !== "string" ||
        !input.file ||
        typeof input.fileName !== "string" ||
        !input.fileName.trim() ||
        input.fileName.length > 255 ||
        /[\u0000-\u001f]/.test(input.fileName) ||
        typeof input.fileType !== "string" ||
        !/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/i.test(input.fileType) ||
        input.fileType.length > 127 ||
        (input.forceOCR !== undefined && typeof input.forceOCR !== "boolean") ||
        (input.forceOcr !== undefined && typeof input.forceOcr !== "boolean")
      )
        throw Error();
      fileName = input.fileName;
      originalType = input.fileType.toLowerCase();
      if (input.file.length > Math.ceil(MAX_FILE_BYTES / 3) * 4)
        return reply("error", "file_too_large", 413);
      // Strict padded base64, not a URL or data URL. Bound before decoding.
      if (
        input.file.length % 4 !== 0 ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(input.file)
      )
        throw Error();
    } catch {
      return reply("error", "invalid_request", 400);
    }

    let bytes: Uint8Array;
    try {
      const binary = atob(input.file);
      if (binary.length > MAX_FILE_BYTES)
        return reply("error", "file_too_large", 413);
      bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    } catch {
      return reply("error", "invalid_request", 400);
    }

    // The existing maintenance RPC is the public wrapper around aim_require_live_session.
    // AccountMaintenance is operation-specific, so reuse its HTTP contract, not its handler.
    const anon = runtime.env("SUPABASE_ANON_KEY");
    let base: URL;
    try {
      if (!anon) throw Error();
      base = backendOrigin(runtime.env);
    } catch {
      return reply("error", "not_configured", 503);
    }
    const call = (path: string, init: RequestInit = {}) =>
      runtime.fetch(new URL(path, base), {
        ...init,
        redirect: "error",
        signal: AbortSignal.timeout(10_000),
        headers: {
          apikey: anon!,
          Authorization: bearer,
          "Content-Type": "application/json",
        },
      });
    try {
      const auth = await call("/auth/v1/user");
      if (!auth.ok) {
        await auth.body?.cancel();
        return reply("error", "unauthorized", 401);
      }
      const user: unknown = JSON.parse(await boundedBody(auth, 65536));
      if (
        !user ||
        typeof user !== "object" ||
        !("id" in user) ||
        typeof user.id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
          user.id,
        )
      )
        return reply("error", "unauthorized", 401);
      const live = await call("/rest/v1/rpc/aim_maintenance_session", {
        method: "POST",
        body: "{}",
      });
      if (!live.ok) {
        await live.body?.cancel();
        return reply("error", "session_revoked", 401);
      }
      if (JSON.parse(await boundedBody(live, 64)) !== true)
        return reply("error", "session_revoked", 401);
    } catch {
      return reply("error", "service_unavailable", 503);
    }

    if (input.forceOCR || input.forceOcr)
      return reply("needs_ocr", "ocr_unavailable");
    if (originalType.startsWith("image/"))
      return reply("needs_ocr", "image_requires_ocr");
    if (originalType === "application/pdf")
      return reply("needs_ocr", "unsupported_pdf");
    if (
      originalType.startsWith(
        "application/vnd.openxmlformats-officedocument.",
      ) ||
      [
        "application/msword",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
      ].includes(originalType)
    )
      return reply("error", "unsupported_office");
    const plainText =
      (originalType.startsWith("text/") &&
        originalType !== "text/html" &&
        originalType !== "text/rtf") ||
      [
        "application/json",
        "application/xml",
        "application/javascript",
        "application/typescript",
        "application/x-yaml",
      ].includes(originalType);
    if (!plainText) return reply("error", "unsupported_type");
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trim();
    } catch {
      return reply("error", "invalid_text_encoding");
    }
    if (!text) return reply("error", "no_text");
    if (text.length > MAX_TEXT_CHARACTERS)
      return reply("error", "extracted_text_too_large");
    return reply("ok", undefined, 200, text);
  };
}
