export function statesExpiredCertificateCause(text: string): boolean {
  const names = /\bexpir(?:ed|y|ation)\b/iu.test(text) && /\bcert(?:ificate)?s?\b/iu.test(text);
  const contradicts = /\b(?:not|never)\s+(?:yet\s+)?expired\b|n't\s+(?:yet\s+)?expired\b|\bhealthy\b|environment variable/iu.test(text);
  return names && !contradicts;
}
