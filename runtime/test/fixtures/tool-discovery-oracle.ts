const SENTENCE_BREAK = /(?<=[.!?])\s+|\n+/u;
const ROOT_CAUSE_LABEL = /\broot cause(?:\s+(?:is|was))?\s*:\s*/giu;
const EXPIRED_CERTIFICATE = [
  /^(?:(?:an?|the)\s+)?expired\s+(?:(?:TLS|SSL)\s+)?cert(?:ificate)?\b/iu,
  /^the\s+(?:(?:staging\s+)?relay['’]s\s+)?(?:(?:TLS|SSL)\s+)?cert(?:ificate)?(?:\s+on\s+the\s+staging\s+relay)?\s+(?:had|has|was)\s+expired\b/iu,
];
const NEGATION = /\b(?:no|not|never|none|nor|neither|without)\b|n['’]t\b/iu;

export function statesExpiredCertificateCause(text: string): boolean {
  const verdicts = text.replace(/[*_`]/gu, "").split(SENTENCE_BREAK).flatMap((sentence) =>
    [...sentence.matchAll(ROOT_CAUSE_LABEL)].map((label) => {
      const cause = sentence.slice(label.index + label[0].length);
      return EXPIRED_CERTIFICATE.some((shape) => shape.test(cause)) && !NEGATION.test(sentence);
    }));
  return verdicts.length > 0 && verdicts.every(Boolean);
}
