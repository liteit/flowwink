import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Strip HTML tags from a string and collapse whitespace. Used for plain-text
 * contexts like blog card excerpts, where a stored excerpt may have been sliced
 * straight from HTML/markdown content and would otherwise render raw `<p>` tags.
 */
export function stripHtml(input: string | null | undefined): string {
  if (!input) return "";
  return input.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}
