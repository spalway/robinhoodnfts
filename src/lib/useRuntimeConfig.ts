// React binding for the runtime deployment config.
//
// Two jobs. It re-renders a component when the config changes, and it is what
// starts the polling in the first place — so the mint address an operator edits
// in Supabase reaches an already-open tab without anyone pressing reload.
import { useEffect, useSyncExternalStore } from 'react'
import {
  getRuntimeConfig,
  loadRuntimeConfig,
  subscribeRuntimeConfig,
  type RuntimeConfig,
} from './runtimeConfig'

/**
 * How often to re-read. Fifteen seconds is the same cadence the payout desk
 * polls at, chosen for the same reason: it is fast enough that "instant" is a
 * fair description to an operator watching the page, and slow enough that a busy
 * site is not hammering PostgREST for a row that changes once a month.
 */
const POLL_MS = 15_000

let started = false

/**
 * Kick the first load exactly once per page, no matter how many components ask.
 *
 * Without this guard every mounted consumer would fire its own initial fetch —
 * the header, the mint gate and the token page would each request the same row
 * on load.
 */
function ensureStarted() {
  if (started) return
  started = true
  void loadRuntimeConfig()
}

export function useRuntimeConfig(): RuntimeConfig {
  const config = useSyncExternalStore(subscribeRuntimeConfig, getRuntimeConfig, getRuntimeConfig)

  useEffect(() => {
    ensureStarted()
    const id = window.setInterval(() => void loadRuntimeConfig(), POLL_MS)

    // Poll on wake as well as on a timer. A laptop that slept for an hour has a
    // config an hour stale and an interval that has not fired; refetching when
    // the tab becomes visible is what stops the first action after a reopen from
    // using yesterday's mint address.
    const onVisible = () => {
      if (document.visibilityState === 'visible') void loadRuntimeConfig()
    }
    document.addEventListener('visibilitychange', onVisible)

    return () => {
      window.clearInterval(id)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [])

  return config
}
