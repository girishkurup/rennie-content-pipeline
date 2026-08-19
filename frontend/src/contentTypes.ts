export interface ContentTypeDef {
  id: string;
  label: string;
  description: string;
  available: boolean;
}

export const CONTENT_TYPES: ContentTypeDef[] = [
  {
    id: "web-article",
    label: "Web Article",
    description: "A longer-form educational or campaign article for a brand website.",
    available: true,
  },
  {
    id: "product-detail-page",
    label: "Product Detail Page (Amazon)",
    description: "Amazon listing copy — title, bullets, description.",
    available: false,
  },
  {
    id: "consumer-email",
    label: "Consumer Email",
    description: "A direct-to-consumer marketing or informational email.",
    available: false,
  },
  {
    id: "social-media-posting",
    label: "Social Media Posting",
    description: "A short-form post for a social channel.",
    available: false,
  },
];

// Placeholder option lists — swap for the real market/brand/persona master
// data before any real use.
export const MARKETS = ["United Kingdom", "Germany", "France", "Spain", "Italy", "United States"];

export const LANGUAGES = ["English", "German", "French", "Spanish", "Italian"];

export const BRANDS = ["Rennie", "Aspirin", "Bepanthen", "Canesten", "Claritin"];

export const TARGET_GROUPS = ["Consumer", "Healthcare Professional", "Caregiver", "Patient"];

export const PERSONAS = [
  "Health-conscious parent",
  "Time-pressed professional",
  "Senior managing a chronic condition",
  "First-time patient",
];

export const CONTENT_GOALS = ["Educational", "Campaign"] as const;

// Sources the agent is allowed to be pointed at for reference material.
// Enforced here as a UI allowlist for now — the agent itself doesn't fetch
// the URL yet (see WebArticleForm.tsx), it's passed through as citation
// context, so this list isn't a security boundary today.
export const ALLOWED_SOURCES = [
  "NHS",
  "NICE",
  "MHRA",
  "PAGB",
  "Peer-reviewed journal",
  "WHO",
  "EMA",
  "Cochrane Library",
  "Bayer approved source",
] as const;
