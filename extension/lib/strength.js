// Master-password strength estimate (no network, no dictionary download).
// Rough entropy with penalties for the patterns attackers try first.
const COMMON = ["password", "passw0rd", "qwerty", "letmein", "welcome", "admin", "iloveyou", "monkey", "dragon",
  "football", "baseball", "master", "shadow", "sunshine", "princess", "abc123", "123456", "totem", "secret", "google"];

export function strength(pw) {
  const s = String(pw || "");
  if (!s) return { score: 0, label: "", hint: "" };
  let pool = 0;
  if (/[a-z]/.test(s)) pool += 26;
  if (/[A-Z]/.test(s)) pool += 26;
  if (/[0-9]/.test(s)) pool += 10;
  if (/[^a-zA-Z0-9]/.test(s)) pool += 33;
  let bits = s.length * Math.log2(Math.max(pool, 1));
  const lower = s.toLowerCase();
  if (COMMON.some((w) => lower.includes(w))) bits -= 28;
  if (/(.)\1\1/.test(s)) bits -= 10;                                     // aaa
  if (/(012|123|234|345|456|567|678|789|abc|bcd|cde|qwe|wer|asd)/i.test(s)) bits -= 10;
  if (/^[a-z]+\d{1,4}[^a-z0-9]?$/i.test(s)) bits -= 12;                 // Word1234!
  const words = s.trim().split(/[\s\-_.]+/).filter((w) => w.length >= 3);
  if (words.length >= 4) bits = Math.max(bits, 60);                       // passphrase of 4+ words
  const score = s.length < 10 ? 0 : bits < 40 ? 1 : bits < 60 ? 2 : bits < 80 ? 3 : 4;
  const label = ["Too short", "Weak", "Fair", "Strong", "Excellent"][score];
  const hint = score === 0 ? "Use at least 10 characters."
    : score === 1 ? "Easy to guess. Try four random words, like “copper lantern orbit mango”."
    : score === 2 ? "Okay. A few more words or characters make it much stronger."
    : "";
  return { score, label, hint };
}
