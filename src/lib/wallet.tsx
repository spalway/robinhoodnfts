// EIP-1193 wallet connect, plus one narrowly-scoped signing path.
//
// This replaces the Wallet Standard implementation the Solana build used. The
// contract it exposes upstream is unchanged — `address`, `connect`,
// `disconnect`, `signAndSendTransaction` — so nothing outside this file and
// lib/evm.ts had to move.
//
// Deliberately not wagmi or RainbowKit: both bring a styled modal we would have
// to fight, and the whole surface needed here is four RPC methods on an
// injected provider. This detects EIP-6963 providers directly and renders in
// the app's own aesthetic.
//
// Signing exists for exactly one purpose — the 10,000 $XAS transfer that gates
// minting. Nothing else in the app calls it, and it is never invoked except
// from an explicit click. Everything else stays read-only.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { CHAIN_ID_HEX, CHAIN_NAME, DEFAULT_RPC, classifySendError, isEvmError, normalise, type MintRequest } from './evm'

export interface DetectedWallet {
  name: string
  icon?: string
}

interface WalletState {
  wallets: DetectedWallet[]
  address: string | null
  connecting: boolean
  error: string | null
  /** The chain the wallet is actually on, or null before it has been asked. */
  chainId: string | null
  onRightChain: boolean
  connect: (name: string) => Promise<void>
  disconnect: () => void
  /** Prompts the wallet to switch to Robinhood Chain, adding it if unknown. */
  switchChain: () => Promise<void>
  /**
   * Signs and sends, returning the transaction hash.
   *
   * Null when no wallet is connected — the caller must treat that as "minting
   * is unavailable", not as a silent no-op.
   */
  signAndSendTransaction: ((request: MintRequest) => Promise<string>) | null
}

const Ctx = createContext<WalletState | null>(null)

const STORAGE_KEY = 'xnfts:wallet'

// ---------------------------------------------------------------------------
// EIP-1193 / EIP-6963
// ---------------------------------------------------------------------------

interface Eip1193Provider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
  on?: (event: string, handler: (...args: unknown[]) => void) => void
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void
}

interface ProviderDetail {
  info: { uuid: string; name: string; icon?: string; rdns: string }
  provider: Eip1193Provider
}

/**
 * EIP-6963 rather than `window.ethereum`.
 *
 * With several wallets installed they all fight over that one property and the
 * winner is whichever injected last — so a visitor with MetaMask and Rabby gets
 * whichever they did not intend. 6963 has each provider announce itself, which
 * is how a picker can offer the real list.
 *
 * `window.ethereum` is still used as a fallback, because a wallet that predates
 * 6963 announces nothing and would otherwise be invisible.
 */
function discover(): ProviderDetail[] {
  const found = new Map<string, ProviderDetail>()

  const onAnnounce = (event: Event) => {
    const detail = (event as CustomEvent<ProviderDetail>).detail
    if (detail?.info?.uuid) found.set(detail.info.uuid, detail)
  }

  window.addEventListener('eip6963:announceProvider', onAnnounce)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
  window.removeEventListener('eip6963:announceProvider', onAnnounce)

  if (found.size === 0) {
    const injected = (window as unknown as { ethereum?: Eip1193Provider }).ethereum
    if (injected) {
      found.set('injected', {
        info: { uuid: 'injected', name: 'Browser Wallet', rdns: 'injected' },
        provider: injected,
      })
    }
  }

  return [...found.values()]
}

export function WalletProvider({ children }: { children: ReactNode }) {
  const [details, setDetails] = useState<ProviderDetail[]>([])
  const [address, setAddress] = useState<string | null>(null)
  const [chainId, setChainId] = useState<string | null>(null)
  const [connecting, setConnecting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const active = useRef<Eip1193Provider | null>(null)

  // Announcements can arrive after first paint, so this runs once on mount and
  // again shortly after — a wallet that injects late would otherwise never show.
  useEffect(() => {
    setDetails(discover())
    const t = window.setTimeout(() => setDetails(discover()), 400)
    return () => window.clearTimeout(t)
  }, [])

  const attach = useCallback((provider: Eip1193Provider) => {
    active.current = provider
    const onAccounts = (...args: unknown[]) => {
      const accounts = args[0] as string[] | undefined
      const next = accounts?.[0] ?? null
      setAddress(next ? normalise(next) : null)
      if (!next) window.localStorage.removeItem(STORAGE_KEY)
    }
    const onChain = (...args: unknown[]) => setChainId(String(args[0] ?? ''))
    provider.on?.('accountsChanged', onAccounts)
    provider.on?.('chainChanged', onChain)
  }, [])

  const connect = useCallback(
    async (name: string) => {
      const detail = details.find((d) => d.info.name === name) ?? details[0]
      if (!detail) {
        setError('No wallet found. Install MetaMask, Rabby or another EVM wallet.')
        return
      }

      setConnecting(true)
      setError(null)
      try {
        const accounts = (await detail.provider.request({ method: 'eth_requestAccounts' })) as string[]
        const first = accounts?.[0]
        if (!first) {
          setError('That wallet returned no account.')
          return
        }
        const chain = (await detail.provider.request({ method: 'eth_chainId' })) as string
        attach(detail.provider)
        setAddress(normalise(first))
        setChainId(chain)
        window.localStorage.setItem(STORAGE_KEY, detail.info.name)
      } catch (e) {
        const err = classifySendError(e)
        setError(err.message)
      } finally {
        setConnecting(false)
      }
    },
    [details, attach],
  )

  const disconnect = useCallback(() => {
    // EIP-1193 has no disconnect. The wallet keeps its permission; this drops
    // the app's own reference, which is the only thing it can honestly do.
    active.current = null
    setAddress(null)
    setChainId(null)
    setError(null)
    window.localStorage.removeItem(STORAGE_KEY)
  }, [])

  /**
   * Switch, and ADD if the wallet has never heard of the chain.
   *
   * 4902 is the "unrecognized chain" code, and it is the normal answer the
   * first time anyone points a wallet at Robinhood Chain — so it is handled
   * rather than surfaced as a failure.
   */
  const switchChain = useCallback(async () => {
    const provider = active.current
    if (!provider) return
    setError(null)
    try {
      await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_ID_HEX }] })
    } catch (e) {
      if ((e as { code?: number })?.code !== 4902) {
        setError(classifySendError(e).message)
        return
      }
      try {
        await provider.request({
          method: 'wallet_addEthereumChain',
          params: [
            {
              chainId: CHAIN_ID_HEX,
              chainName: CHAIN_NAME,
              rpcUrls: [DEFAULT_RPC],
              blockExplorerUrls: ['https://robinhoodchain.blockscout.com'],
              // Gas is ETH; the chain has no native token of its own.
              nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
            },
          ],
        })
      } catch (addError) {
        setError(classifySendError(addError).message)
      }
    }
  }, [])

  const signAndSendTransaction = useMemo(() => {
    const provider = active.current
    if (!provider || !address) return null
    return async (request: MintRequest): Promise<string> => {
      const hash = await provider.request({ method: 'eth_sendTransaction', params: [request] })
      return String(hash)
    }
  }, [address, chainId])

  const value = useMemo<WalletState>(
    () => ({
      wallets: details.map((d) => ({ name: d.info.name, icon: d.info.icon })),
      address,
      chainId,
      onRightChain: chainId === CHAIN_ID_HEX,
      connecting,
      error,
      connect,
      disconnect,
      switchChain,
      signAndSendTransaction,
    }),
    [details, address, chainId, connecting, error, connect, disconnect, switchChain, signAndSendTransaction],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useWallet(): WalletState {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useWallet must be used inside WalletProvider')
  return ctx
}

// Re-exported so callers that only need the error shape do not import evm.ts
// and drag the whole chain layer in behind them.
export { isEvmError }
