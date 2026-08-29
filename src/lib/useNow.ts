import { useEffect, useState } from 'react'

/**
 * A ticking clock. Accrual is a pure function of time, so re-rendering against
 * a moving `now` is what makes yield visibly tick up with nothing stored.
 */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])

  return now
}
