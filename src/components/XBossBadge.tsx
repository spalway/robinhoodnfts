/**
 * The ladder, ascending. It used to live in lib/network alongside the generated
 * holder list; the thresholds now live in the `xnft_ranks` table and the label
 * arrives as a string on each leaderboard row, so this is the only place the
 * four names still need to be known.
 */
export type XBoss = 'BOSS' | 'DIRECTOR' | 'VP' | 'CEO'

/**
 * Anything the database sends that is not one of the four falls back to BOSS.
 * An unrecognised rank is a schema drift, not a reason to crash a table that is
 * otherwise fine — and BOSS is the bottom rung, so guessing wrong never inflates
 * anybody.
 */
export function asXBoss(value: string | null | undefined): XBoss {
  return value === 'CEO' || value === 'VP' || value === 'DIRECTOR' ? value : 'BOSS'
}

/**
 * xBoss rank banner. Seniority is colour-coded, label always white — except
 * BOSS, which stays a quiet outline so the ladder still reads bottom-to-top.
 *
 * CEO is a gold plate with a metallic sweep travelling across it; the sweep is
 * a separate absolutely-positioned layer rather than a background-position
 * animation, because animating transform stays on the compositor and a grid of
 * these would otherwise repaint constantly.
 */
const STYLES: Record<XBoss, string> = {
  CEO: 'xboss-ceo',
  VP: 'xboss-vp',
  DIRECTOR: 'xboss-director',
  BOSS: 'border border-rule text-ink-mute',
}

/** CEO wears the brand prefix; the rest are plain rank names. */
const LABELS: Record<XBoss, string> = {
  CEO: 'xCEO',
  VP: 'VP',
  DIRECTOR: 'DIRECTOR',
  BOSS: 'BOSS',
}

export function XBossBadge({ rank, size = 'sm' }: { rank: XBoss; size?: 'sm' | 'lg' }) {
  const text = size === 'lg' ? 'ui-11' : 'ui-10'
  const isCeo = rank === 'CEO'

  return (
    <span
      className={`ui ${text} relative inline-block overflow-hidden px-2 py-1 align-middle ${STYLES[rank]}`}
      title={`xBoss rank: ${LABELS[rank]}`}
    >
      {isCeo ? (
        <span className="xboss-shine pointer-events-none absolute inset-y-0 -left-1/3 w-1/2" aria-hidden />
      ) : null}
      {/* keep-case protects the lowercase x in xCEO from the uppercase rule. */}
      <span className={`relative ${isCeo ? 'keep-case' : ''}`}>{LABELS[rank]}</span>
    </span>
  )
}
