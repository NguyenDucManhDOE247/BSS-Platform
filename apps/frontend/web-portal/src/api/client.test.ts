import { describe, expect, it } from 'vitest';
import { formatVND } from './client';

// B-04 fix: ci-frontend.yml runs `npm test` (vitest run) and there wasn't a single test file
// in either frontend app — `vitest run` with zero test files exits non-zero, so CI was
// guaranteed red the moment someone actually looked at it, regardless of what the app code did.
// Intl.NumberFormat('vi-VN', ...) separates the amount from the ₫ symbol with U+00A0
// NO-BREAK SPACE, not a regular U+0020 space — they render identically in a terminal/editor
// but fail a strict string `toBe` comparison against a literal typed with a normal space.
// Found by actually running this test, not by guessing at the expected output.
const NBSP = ' ';

describe('formatVND', () => {
  it('formats a whole VND amount with the currency symbol', () => {
    expect(formatVND(199000)).toBe(`199.000${NBSP}₫`);
  });

  it('formats zero', () => {
    expect(formatVND(0)).toBe(`0${NBSP}₫`);
  });
});
