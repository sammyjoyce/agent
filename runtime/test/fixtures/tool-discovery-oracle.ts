const SENTENCE_BREAK = /(?<=[.!?])\s+|\n+/u;
const CLAUSE_BREAK = /\s*(?:[;—–]|--|\b(?:but|however|yet|whereas|although|though)\b)\s*/iu;
const REPLACEMENT_SPLIT = /\b(?:instead\s+of|rather\s+than|as\s+opposed\s+to)\b/iu;
const ROOT_CAUSE_LABEL = /\broot\s+cause(?:\s*\([^)]*\))?(?:\s+(?:is|was))?\s*:\s*/giu;

const CERT_TOKEN = /\b(?:(?:tls|ssl|x\.?509)\s+)?cert(?:ificate)?s?\b/iu;
const EXPIRY_TOKEN = /\b(?:expir(?:ed|es?|ing|ation|y)|lapsed|out[\s-]+of[\s-]+date|past\s+(?:its\s+)?(?:validity|notafter))\b/iu;
const CERT_VALID_STATE = /\b(?:(?:is|was|are|were|remained|remains|stay(?:s|ed)?|looks?|appears?)\s+(?:still\s+)?(?:valid|unexpired|current|up\s+to\s+date|healthy|intact)|(?:has|had|was)\s+not\s+(?:yet\s+)?(?:expired|lapsed)|(?:hasn['’]t|hadn['’]t|didn['’]t)\s+(?:expired?|lapsed?)|no\s+(?:expired\s+)?cert(?:ificate)?\s+(?:issue|problem|error|expiry)|never\s+expired)\b/iu;
const CERT_EXPIRY_NEGATED = /\b(?:no|not|without|never|neither|nor|none|wasn['’]t|weren['’]t|isn['’]t|aren['’]t|hadn['’]t|hasn['’]t|didn['’]t|wouldn['’]t|couldn['’]t|shouldn['’]t)\s+(?:caused\s+by\s+|due\s+to\s+|from\s+|triggered\s+by\s+|attributable\s+to\s+)?(?:(?:an?|any|the)\s+)?expired\s+(?:(?:tls|ssl|x\.?509)\s+)?cert(?:ificate)?s?\b|\bcert(?:ificate)?s?\b[^.?!;\n]{0,40}\b(?:(?:was|were|is|are|had|has)\s+not\s+(?:yet\s+)?(?:expir(?:e|ed)|lapsed)|(?:wasn['’]t|weren['’]t|isn['’]t|aren['’]t|hadn['’]t|hasn['’]t|didn['’]t)\s+(?:expir(?:e|ed)|lapsed?))\b/iu;
const HYPOTHESIS_REJECTION = /\b(?:rul(?:e|ed|es|ing)\s+out|exclud(?:e|ed|ing)|eliminat(?:e|ed|ing)|dismiss(?:ed|es|ing)?|discard(?:ed|es|ing)?(?:\s+(?:the\s+|this\s+|that\s+)?theory)?|(?:is|was|are|were|been|got|remains?)\s+rejected|reject(?:ed|s|ing)?\s+(?:the\s+|this\s+|that\s+|such\s+|any\s+)?(?:theory|hypothesis|cause|explanation|finding|claim|idea|option|possibility|attribution|cert(?:ificate)?\s+(?:theory|hypothesis|cause|explanation))|reject(?:ed|s|ing)?\s+(?:it\s+)?as\s+(?:a\s+|the\s+)?(?:root\s+)?cause|disprov(?:e|ed|en|ing)|refut(?:e|ed|ing)|debunk(?:ed|s|ing)?|falsif(?:y|ied|ies|ing)|not\s+(?:caused\s+by|due\s+to|from|triggered\s+by|attributable\s+to)|not\s+(?:the\s+)?(?:actual\s+|real\s+|true\s+|primary\s+|underlying\s+)?(?:root\s+)?cause|wasn['’]t\s+(?:the\s+)?(?:root\s+)?cause|isn['’]t\s+(?:the\s+)?(?:root\s+)?cause|did\s+not\s+(?:cause|break|fail\s+due\s+to|reject)|didn['’]t\s+(?:cause|break|reject)|unrelated(?:\s+to\s+the\s+(?:failure|outage|issue|error))?|red\s+herring|false\s+(?:alarm|lead|positive|theory)|misattribut(?:e|ed|ing)|misdiagnos(?:e|ed|ing)|unlikely\s+(?:cause|reason))\b/iu;
const ANAPHORIC_SUBJECT = /\b(?:that|this|it|such\s+(?:a\s+)?(?:theory|hypothesis|cause|finding)|the\s+(?:earlier|previous|initial|first)\s+(?:theory|hypothesis|finding|conclusion|cause))\b/iu;
const ALTERNATIVE_CORRECTION = /^(?:correction|update|wait|no[,:]|actually[,:\s]|upon\s+(?:further\s+|closer\s+)?(?:check|inspection|review))/iu;
const ROOT_CAUSE_ASSIGNMENT = /\b(?:actual|real|true)\s+(?:root\s+)?cause\b/iu;

function normalizeText(text: string): string {
  return text.replace(/[`*_#]/gu, "").replace(/\s+/gu, " ").trim();
}

function mentionsCertExpiry(span: string): boolean {
  if (!CERT_TOKEN.test(span) || !EXPIRY_TOKEN.test(span)) return false;
  return /\bexpir(?:ed|es?|ing|ation|y)\b[\w\s,'’-]{0,30}\b(?:(?:tls|ssl|x\.?509)\s+)?cert(?:ificate)?s?\b/iu.test(span) ||
    /\b(?:(?:tls|ssl|x\.?509)\s+)?cert(?:ificate)?s?\b[\w\s,'’-]{0,50}\b(?:expir(?:ed|es?|ing|ation|y)|lapsed|out[\s-]+of[\s-]+date|past\s+(?:its\s+)?(?:validity|notafter))\b/iu.test(span);
}

type SentencePolarity = { affirmed: boolean; denied: boolean; anaphoricRetraction: boolean };

function classifySentence(sentence: string): SentencePolarity {
  const clauses = sentence.split(CLAUSE_BREAK).map((clause) => clause.trim()).filter((clause) => clause.length > 0);
  let affirmed = false;
  let denied = false;
  let anaphoricRetraction = false;

  for (const clause of clauses) {
    const replacementMatch = REPLACEMENT_SPLIT.exec(clause);
    if (replacementMatch !== null) {
      const before = clause.slice(0, replacementMatch.index);
      const after = clause.slice(replacementMatch.index + replacementMatch[0].length);
      if (mentionsCertExpiry(after)) denied = true;
      if (mentionsCertExpiry(before) && !HYPOTHESIS_REJECTION.test(before) && !CERT_EXPIRY_NEGATED.test(before) && !CERT_VALID_STATE.test(before)) {
        if (/^(?:rather\s+than|instead\s+of)\b/iu.test(clause)) denied = true;
        else affirmed = true;
      }
      continue;
    }
    if (CERT_VALID_STATE.test(clause) || CERT_EXPIRY_NEGATED.test(clause)) {
      if (CERT_TOKEN.test(clause)) denied = true;
      continue;
    }
    if (!mentionsCertExpiry(clause)) {
      if ((ANAPHORIC_SUBJECT.test(clause) && HYPOTHESIS_REJECTION.test(clause)) ||
        (ALTERNATIVE_CORRECTION.test(clause) && (HYPOTHESIS_REJECTION.test(clause) || ROOT_CAUSE_ASSIGNMENT.test(clause)))) {
        anaphoricRetraction = true;
      }
      continue;
    }
    if (HYPOTHESIS_REJECTION.test(clause) || /\bnot\b(?:\s+be)?\s+(?:due|attributable)\s+to\b/iu.test(clause)) {
      denied = true;
      continue;
    }
    affirmed = true;
  }
  return { affirmed, denied, anaphoricRetraction };
}

/**
 * Check whether an agent's final explanation labels an expired TLS/SSL
 * certificate as the root cause without negating, excluding, or retracting it.
 */
export function statesExpiredCertificateCause(text: string): boolean {
  const clean = text.replace(/[`*_#]/gu, "");
  const matches = [...clean.matchAll(ROOT_CAUSE_LABEL)];
  if (matches.length === 0) return false;

  const prefix = clean.slice(0, matches[0]!.index ?? 0);
  const prefixEndSentence = prefix.split(SENTENCE_BREAK).at(-1) ?? prefix;
  if (/\bnot\b\s+(?:the\s+)?$/iu.test(prefixEndSentence) ||
      (HYPOTHESIS_REJECTION.test(prefixEndSentence) && !/\bdo\s+not\b/iu.test(prefixEndSentence))) {
    return false;
  }

  for (let index = 0; index < matches.length; index++) {
    const start = (matches[index]!.index ?? 0) + matches[index]![0].length;
    const end = matches[index + 1]?.index ?? clean.length;
    const body = clean.slice(start, end);
    const sentences = body
      .split(/\n+/u)
      .flatMap((line) => line.split(SENTENCE_BREAK))
      .map(normalizeText)
      .filter((sentence) => sentence.length > 0);
    if (sentences.length === 0) return false;

    const first = classifySentence(sentences[0]!);
    if (!first.affirmed || first.denied || first.anaphoricRetraction) return false;

    for (const later of sentences.slice(1)) {
      const verdict = classifySentence(later);
      if (verdict.denied || verdict.anaphoricRetraction) return false;
      if ((ALTERNATIVE_CORRECTION.test(later) || ROOT_CAUSE_ASSIGNMENT.test(later)) && !verdict.affirmed) return false;
    }
  }
  return true;
}
