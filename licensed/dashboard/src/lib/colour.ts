// Readable text on a colour: black or white, whichever contrasts more
// (WCAG), as authmk's own pages work it out.

function channel(value: number): number {
  const c = value / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function luminance(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((start) => parseInt(hex.slice(start, start + 2), 16));
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

export const isColour = (value: string | null | undefined): value is string => !!value && /^#[0-9a-f]{6}$/i.test(value);

export function contentColour(hex: string): "#000000" | "#ffffff" {
  const light = luminance(hex);
  const onBlack = (light + 0.05) / 0.05;
  const onWhite = 1.05 / (light + 0.05);
  return onBlack >= onWhite ? "#000000" : "#ffffff";
}
