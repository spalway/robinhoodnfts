// Deterministic RNG. Everything the protocol "knows" — tiers, skills, traits,
// hire times — derives from these functions, so the whole collection
// regenerates identically on every machine with no stored state.

/** FNV-1a. Stable across runs and platforms, unlike String.hashCode-style rolls. */
export function hashString(input: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return h >>> 0
}

export type Rng = () => number

/** mulberry32 — small, fast, and good enough for visual/simulated distribution. */
export function mulberry32(seed: number): Rng {
  let a = seed >>> 0
  return function () {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** Seed an RNG from any string (a mint address, an id, a namespaced key). */
export function rngFrom(...parts: string[]): Rng {
  return mulberry32(hashString(parts.join(':')))
}

export function randInt(rng: Rng, minInclusive: number, maxInclusive: number): number {
  return minInclusive + Math.floor(rng() * (maxInclusive - minInclusive + 1))
}

export function pick<T>(rng: Rng, items: readonly T[]): T {
  return items[Math.floor(rng() * items.length)]
}

/**
 * Weighted pick. Weights need not sum to 1.
 * Returns the last item if float drift overshoots.
 */
export function pickWeighted<T>(rng: Rng, items: readonly T[], weightOf: (item: T) => number): T {
  let total = 0
  for (const item of items) total += weightOf(item)

  let roll = rng() * total
  for (const item of items) {
    roll -= weightOf(item)
    if (roll <= 0) return item
  }
  return items[items.length - 1]
}

/** Weighted pick of `count` DISTINCT items. Throws rather than silently returning fewer. */
export function pickDistinct<T>(
  rng: Rng,
  items: readonly T[],
  count: number,
  weightOf: (item: T) => number = () => 1,
): T[] {
  if (count > items.length) {
    throw new Error(`pickDistinct: asked for ${count} of ${items.length}`)
  }
  const pool = [...items]
  const out: T[] = []
  for (let i = 0; i < count; i++) {
    const chosen = pickWeighted(rng, pool, weightOf)
    out.push(chosen)
    pool.splice(pool.indexOf(chosen), 1)
  }
  return out
}

/** Deterministic pseudo-Solana address. Base58 alphabet, 44 chars, never a real key. */
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
export function fakeAddress(seed: string): string {
  const rng = rngFrom('addr', seed)
  let out = ''
  for (let i = 0; i < 44; i++) out += B58[Math.floor(rng() * B58.length)]
  return out
}
