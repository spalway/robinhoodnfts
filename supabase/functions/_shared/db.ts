// Service-role access to PostgREST.
//
// Plain fetch again rather than @supabase/supabase-js: the only three things
// these functions do to the database are call a writer RPC, read pending payouts,
// and read one boolean. A client library would add a dependency for URL building.
//
// The service-role key bypasses RLS, so this module is the one place in the whole
// backend with unrestricted write access. It never leaves the server, it is never
// echoed into a response, and every write it performs goes through a SECURITY
// DEFINER function whose body is fixed in a migration — so even a bug here cannot
// write an arbitrary row into an arbitrary table.
import { fnError, type FnError } from './http.ts'
import type { PlatformConfig } from './env.ts'

function headers(config: PlatformConfig): Record<string, string> {
  return {
    apikey: config.serviceRoleKey,
    Authorization: `Bearer ${config.serviceRoleKey}`,
    'Content-Type': 'application/json',
  }
}

/**
 * Calls a `public.*` writer function. `Prefer: return=representation` is not set
 * for the record_* family because they return a scalar; the payout functions
 * return a row and PostgREST hands that back as an object either way.
 */
export async function callRpc<T>(
  config: PlatformConfig,
  fn: string,
  args: Record<string, unknown>,
): Promise<T | FnError> {
  try {
    const response = await fetch(`${config.supabaseUrl}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: headers(config),
      body: JSON.stringify(args),
    })
    const text = await response.text()
    if (!response.ok) {
      // The body carries the Postgres error — a domain violation on a money column
      // shows up here, and it is worth surfacing because it means a writer sent
      // something that is not a u64 digit string.
      return fnError('database', `Database rejected ${fn}.`, text.slice(0, 500))
    }
    return (text.length > 0 ? JSON.parse(text) : null) as T
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fnError('database', `Could not reach the database for ${fn}.`, detail)
  }
}

/** A raw PostgREST GET. `query` is a fully-formed query string without the '?'. */
export async function selectRows<T>(
  config: PlatformConfig,
  table: string,
  query: string,
): Promise<T[] | FnError> {
  try {
    const response = await fetch(`${config.supabaseUrl}/rest/v1/${table}?${query}`, {
      method: 'GET',
      headers: headers(config),
    })
    const text = await response.text()
    if (!response.ok) {
      return fnError('database', `Database rejected a read of ${table}.`, text.slice(0, 500))
    }
    const parsed = JSON.parse(text)
    return Array.isArray(parsed) ? (parsed as T[]) : []
  } catch (e) {
    const detail = e instanceof Error ? e.message : 'unknown error'
    return fnError('database', `Could not reach the database to read ${table}.`, detail)
  }
}

export interface PayoutRow {
  id: string
  /**
   * The authoritative amount, in raw units — null until a chain reading produced
   * it. A pending row has no verified amount because no verified amount exists
   * yet, and saying so with a null is more honest than seeding the column with
   * the number the claim asked for and hoping the UI reads the flag beside it.
   */
  amount: string | null
  /** What the client said it was claiming. Never treated as truth by anything. */
  claimed_amount_unverified: string | null
  /** Generated in the database as `amount is not null`. Cannot disagree with the column it describes. */
  amount_verified: boolean
  destination: string
  status: 'pending' | 'confirmed' | 'failed'
  signature: string
  /** Past this height, a signature the chain has never seen definitively never landed. */
  expires_at_block_height: number
  failure_reason: string | null
  requested_at: string
  last_checked_at: string | null
  confirmed_at: string | null
}
