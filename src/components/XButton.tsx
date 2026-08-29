import { twitterHandle, twitterUrl } from '../lib/token'

/**
 * The official X mark.
 *
 * Drawn as a path rather than pulled from an icon set: it is one glyph, and a
 * dependency for one glyph is a dependency to keep updated forever. `currentColor`
 * so it inherits the button's text colour instead of pinning its own.
 */
function XMark({ className = 'h-4 w-4' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={`${className} shrink-0`} fill="currentColor" aria-hidden>
      <path d="M18.9 2H22l-7.1 8.1L23.2 22h-6.6l-5.2-6.8L5.5 22H2.4l7.6-8.7L1.2 2h6.8l4.7 6.2L18.9 2Zm-1.1 18h1.7L7.3 3.8H5.5L17.8 20Z" />
    </svg>
  )
}

/**
 * Link to the project's X account, sitting in the header beside the wallet and
 * the inbox.
 *
 * h-10 and the black fill are not styling choices made here — they match
 * WalletMenu and InboxButton exactly, because the three sit shoulder to shoulder
 * and any difference in height reads as a misalignment rather than as variety.
 *
 * Renders nothing when no handle is configured. A dead link to a profile that
 * does not exist is worse than an absent button, and this follows the same
 * runtime config as everything else, so setting the handle in Supabase makes it
 * appear without a redeploy.
 */
export function XButton() {
  const url = twitterUrl()
  if (!url) return null

  return (
    <a
      href={url}
      target="_blank"
      rel="noreferrer noopener"
      aria-label={`@${twitterHandle()} on X`}
      title={`@${twitterHandle()} on X`}
      className="ui ui-11 flex h-10 w-10 shrink-0 items-center justify-center border border-ink bg-ink text-paper transition-colors hover:bg-ink-mute"
    >
      <XMark className="h-[18px] w-[18px]" />
    </a>
  )
}
