// What authmk tells the page, in a JSON block it adds to the HTML
// (<script type="application/json" id="authmk-page">). Never executed.

export type ErrorPage = {
  name: "error";
  app_name: string;
  code: string;
  message: string;
  home: string;
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
