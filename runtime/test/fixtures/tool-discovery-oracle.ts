const ROOT_CAUSE_LINE = /^[\s>#-]*root cause\s*:\s*(.*)$/gimu;
const EXPIRED_CERTIFICATE = [
  /^(?:(?:an?|the)\s+)?expired\s+(?:(?:TLS|SSL)\s+)?cert(?:ificate)?\b/iu,
  /^the\s+(?:(?:staging\s+)?relay['’]s\s+)?(?:(?:TLS|SSL)\s+)?cert(?:ificate)?(?:\s+on\s+the\s+staging\s+relay)?\s+(?:had|has|was)\s+expired\b/iu,
];
const NEGATION = /\b(?:no|not|never|none|nor|neither|without)\b|n['’]t\b/iu;

export function statesExpiredCertificateCause(text: string): boolean {
  const causes = [...text.replace(/[*_`]/gu, "").matchAll(ROOT_CAUSE_LINE)].map((match) => (match[1] ?? "").trim());
  return causes.length > 0 && causes.every((cause) => EXPIRED_CERTIFICATE.some((shape) => shape.test(cause)) && !NEGATION.test(cause));
}
