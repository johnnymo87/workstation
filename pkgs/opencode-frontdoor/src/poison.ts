/**
 * Returns true if the Content-Type header represents an HTML response (`text/html`).
 *
 * Performs exact media-type matching (case-insensitive, ignoring parameters such as `charset`).
 *
 * NOTE: Unlike `isEventStreamResponse`, this function MUST NOT use prefix matching (`startsWith`),
 * because `text/htmlx` or other media types starting with `text/html` must not false-positive.
 */
export function isHtmlResponse(contentType: string | string[] | undefined): boolean {
  if (!contentType) {
    return false;
  }
  const rawValue = Array.isArray(contentType) ? contentType[0] : contentType;
  if (typeof rawValue !== "string") {
    return false;
  }
  const mediaType = rawValue.split(";")[0].trim().toLowerCase();
  return mediaType === "text/html";
}
