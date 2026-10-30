// What authmk tells the page, in a JSON block it adds to the HTML
// (<script type="application/json" id="authmk-page">). Never executed.

export type ErrorPage = {
  name: "error";
  app_name: string;
  code: string;
  message: string;
  home: string;
  // The app's branding (Authmk.Branding), or null. The logo is a URL this
  // page may load (same origin); the colours are #rrggbb.
  logo_url: string | null;
  primary_color: string | null;
  primary_content_color: string | null;
};

export type Page = ErrorPage;

export function readPage(): Page | null {
  const element = document.getElementById("authmk-page");
  if (!element?.textContent) return null;

  try {
    return JSON.parse(element.textContent) as Page;
  } catch {
    return null;
  }
}
