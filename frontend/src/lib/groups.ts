/** HTTP API's JWT authorizer flattens the cognito:groups array claim to a
 * string like "[reviewers]" or "[requesters, reviewers]" — parse leniently. */
export function getGroups(user: unknown): string[] {
  const raw = (user as { profile?: Record<string, unknown> } | null | undefined)?.profile?.[
    "cognito:groups"
  ];
  if (!raw) return [];
  if (Array.isArray(raw)) return raw as string[];
  return String(raw)
    .replace(/[[\]]/g, "")
    .split(",")
    .map((g) => g.trim())
    .filter(Boolean);
}

export function isReviewer(user: unknown): boolean {
  return getGroups(user).includes("reviewers");
}
