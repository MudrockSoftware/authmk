import { docs } from "#lib/server/content.ts";
import { site } from "#lib/site.ts";

export const prerender = true;

export function GET() {
  const paths = ["", "examples", ...docs.map((doc) => doc.path)];
  const urls = paths.map((path) => `  <url><loc>${new URL(path, `${site.url}/`).href}</loc></url>`).join("\n");
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls}
</urlset>
`;
  return new Response(body, { headers: { "Content-Type": "application/xml" } });
}
