/**
 * The Solana mark — three slanted bars, drawn inline.
 *
 * Geometry, not an image: a remote asset breaks on a strict-CSP page and on an
 * offline dev box, and a bundled PNG would need two of them to survive the
 * light/dark swap. Fill is `currentColor`, so the mark takes the colour of
 * whatever it sits in and inherits both themes for free.
 *
 * The top and bottom bars lean one way and the middle leans the other, which is
 * the whole silhouette — get that backwards and it reads as a hamburger menu.
 */
export function SolLogo({ size = 12, className = '' }: { size?: number; className?: string }) {
  return (
    <svg
      viewBox="0 0 100 80"
      width={size}
      // Height follows the viewBox ratio rather than being set to `size`, so a
      // caller sizing by width never squashes the bars.
      height={(size * 80) / 100}
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
      className={`shrink-0 ${className}`}
    >
      <path d="M20 0 H100 L80 16 H0 Z" />
      <path d="M0 32 H80 L100 48 H20 Z" />
      <path d="M20 64 H100 L80 80 H0 Z" />
    </svg>
  )
}
