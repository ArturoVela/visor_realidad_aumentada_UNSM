const path = "/models/switch-2960/v1.usdz";
const objectKey = "public-models/switch-2960/v1.usdz";
const size = 394571;

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== path) return new Response(null, { status: 404 });
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const object = request.method === "HEAD"
      ? await env.MODELS.head(objectKey)
      : await env.MODELS.get(objectKey);
    if (!object || object.size !== size) {
      return new Response(null, { status: 503, headers: { "Cache-Control": "no-store" } });
    }
    return new Response(request.method === "HEAD" ? null : object.body, {
      headers: {
        "Content-Type": "model/vnd.usdz+zip",
        "Content-Length": String(size),
        "Cache-Control": "public, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
        ETag: object.httpEtag,
      },
    });
  },
};
