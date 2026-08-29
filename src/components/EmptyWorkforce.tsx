import { Link } from 'react-router-dom'
import { GRID } from '../lib/avatar'

/**
 * What the workforce panel shows while nothing has been minted.
 *
 * A featureless xployee — the silhouette with no traits at all — at low opacity,
 * which is the honest picture: the shape of a worker exists, and nobody has
 * drawn one yet. Every real card on the site is generated from a serial, so
 * rendering a real xployee here would be showing somebody's specific worker as a
 * placeholder for the absence of any.
 *
 * Drawn rather than generated for the same reason. `buildXployee` needs a
 * serial, and there is no serial that means "none".
 */
function Ghost({ size = 148 }: { size?: number }) {
  const u = size / GRID

  // A head, a neck and a pair of shoulders on the same 32-grid the real avatars
  // use, so the proportions match the art it stands in for.
  const px = (x: number, y: number, w: number, h: number) => (
    <rect key={`${x}-${y}`} x={x * u} y={y * u} width={w * u} height={h * u} />
  )

  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      className="pixelated"
      aria-hidden="true"
      style={{ opacity: 0.14 }}
      fill="currentColor"
      shapeRendering="crispEdges"
    >
      {px(11, 6, 10, 11)}
      {px(14, 17, 4, 2)}
      {px(8, 19, 16, 9)}
      {px(6, 21, 2, 7)}
      {px(24, 21, 2, 7)}
    </svg>
  )
}

export function EmptyWorkforce() {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-10 text-center">
      <Ghost />
      <p className="mt-4 max-w-sm text-[12px] leading-relaxed text-ink-mute">
        There are currently no xployees minted to the workforce. Be the first to mint your very own
        xployee.
      </p>
      <Link
        to="/mint"
        className="ui ui-11 mt-4 inline-flex min-h-11 items-center bg-accent px-5 py-2.5 text-accent-ink hover:opacity-90"
      >
        Mint an xployee →
      </Link>
    </div>
  )
}
