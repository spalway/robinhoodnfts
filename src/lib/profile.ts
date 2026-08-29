// Per-wallet profile, stored in the browser.
//
// There is no backend, so identity is whatever the visitor types into their own
// device. Keyed by address, so connecting a different wallet shows a different
// profile rather than leaking one persona across accounts.
//
// Every storage touch is wrapped: a corrupt entry, a full quota, or a browser
// with storage disabled must degrade to "no profile", never to a thrown error
// on a page that is otherwise fine.

export interface Profile {
  username: string
  bio: string
  /** Handle only — no '@', no URL. Normalised on the way in and on the way out. */
  twitter: string
  /** One of the owner's own xployees, rendered as their avatar. */
  pfpXployeeId: number | null
}

export interface ProfileError {
  field: keyof Profile
  message: string
}

export const EMPTY_PROFILE: Profile = {
  username: '',
  bio: '',
  twitter: '',
  pfpXployeeId: null,
}

export const USERNAME_MIN = 3
export const USERNAME_MAX = 20
export const BIO_MAX = 160
export const TWITTER_MAX = 15

const USERNAME_RE = /^[A-Za-z0-9_]{3,20}$/
const TWITTER_RE = /^[A-Za-z0-9_]{1,15}$/

/** Namespaced per address so switching wallets switches profiles. */
function keyFor(address: string): string {
  return `xnfts:profile:${address}`
}

/**
 * Accepts anything a user might paste — a full profile URL, an @handle, a bare
 * handle with stray whitespace — and reduces it to the handle itself.
 */
export function normaliseTwitter(input: string): string {
  const trimmed = input.trim()
  const withoutScheme = trimmed.replace(/^https?:\/\//i, '')
  // Any subdomain, because mobile.twitter.com and www.x.com are both real pastes.
  // A trailing slash is required so a bare 'twitter.com' stays wrong-looking and
  // fails validation rather than silently normalising to an empty handle.
  const withoutHost = withoutScheme.replace(/^(?:[a-z0-9-]+\.)*(?:twitter|x)\.com\//i, '')
  // Drop anything past the handle: /status/…, ?s=20, #fragment.
  const handle = withoutHost.split(/[/?#]/)[0]
  return handle.replace(/^@+/, '').replace(/\s+/g, '')
}

function coerce(value: unknown): Profile {
  if (typeof value !== 'object' || value === null) return { ...EMPTY_PROFILE }
  const raw = value as Partial<Profile>
  const pfp = raw.pfpXployeeId
  return {
    username: typeof raw.username === 'string' ? raw.username : '',
    bio: typeof raw.bio === 'string' ? raw.bio : '',
    twitter: typeof raw.twitter === 'string' ? normaliseTwitter(raw.twitter) : '',
    // Field-by-field so a half-written or hand-edited entry still loads what it can.
    pfpXployeeId: typeof pfp === 'number' && Number.isInteger(pfp) && pfp >= 0 ? pfp : null,
  }
}

export function loadProfile(address: string): Profile {
  if (!address) return { ...EMPTY_PROFILE }
  try {
    const raw = localStorage.getItem(keyFor(address))
    if (!raw) return { ...EMPTY_PROFILE }
    return coerce(JSON.parse(raw))
  } catch {
    // Bad JSON, blocked storage, private mode — an empty profile is the answer.
    return { ...EMPTY_PROFILE }
  }
}

export function saveProfile(address: string, p: Profile): void {
  if (!address) return
  try {
    // Normalise on write, so what is stored is what validation and display agree on.
    const clean: Profile = {
      username: p.username.trim(),
      bio: p.bio.trim(),
      twitter: normaliseTwitter(p.twitter),
      pfpXployeeId: p.pfpXployeeId,
    }
    localStorage.setItem(keyFor(address), JSON.stringify(clean))
  } catch {
    // Quota exceeded or storage unavailable — the edit simply doesn't persist.
  }
}

export function clearProfile(address: string): void {
  if (!address) return
  try {
    localStorage.removeItem(keyFor(address))
  } catch {
    // Nothing to do — there is no state left to reconcile.
  }
}

/**
 * All problems at once, not just the first, so a form can mark every bad field
 * in one pass.
 *
 * A username is required — it is the wallet's display identity, and an unnamed
 * profile is worse than none. Bio, X handle and avatar are all optional and are
 * only checked when actually filled in.
 */
export function validateProfile(p: Profile): ProfileError[] {
  const errors: ProfileError[] = []

  if (!USERNAME_RE.test(p.username.trim())) {
    errors.push({
      field: 'username',
      message: `Username must be ${USERNAME_MIN}–${USERNAME_MAX} characters: letters, numbers or underscore.`,
    })
  }

  if (p.bio.length > BIO_MAX) {
    errors.push({ field: 'bio', message: `Bio must be ${BIO_MAX} characters or fewer.` })
  }

  const twitter = normaliseTwitter(p.twitter)
  if (twitter && !TWITTER_RE.test(twitter)) {
    errors.push({
      field: 'twitter',
      message: `X handle must be 1–${TWITTER_MAX} characters: letters, numbers or underscore.`,
    })
  }

  if (p.pfpXployeeId !== null && (!Number.isInteger(p.pfpXployeeId) || p.pfpXployeeId < 0)) {
    errors.push({ field: 'pfpXployeeId', message: 'Avatar must be an xployee you own.' })
  }

  return errors
}
