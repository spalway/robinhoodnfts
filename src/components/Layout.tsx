import { useEffect, useState } from 'react'
import { NavLink, Outlet, Link, useNavigate } from 'react-router-dom'
import { useWallet } from '../lib/wallet'
import { usePrices } from '../lib/usePrices'
import { shortAddress } from '../lib/format'
import { XButton } from './XButton'
import { useRuntimeConfig } from '../lib/useRuntimeConfig'
import { TickerTape } from './TickerTape'

interface Tab {
  to: string
  label: string
  end?: boolean
  /** Opts the label out of the global uppercase rule — the lowercase x is the brand. */
  keepCase?: boolean
}

const TABS: Tab[] = [
  { to: '/', label: 'Overview', end: true },
  { to: '/mint', label: 'Mint' },
  { to: '/xnet', label: 'xNET', keepCase: true },
  { to: '/profile', label: 'Profile' },
]


/**
 * The wordmark — the one and only place m42 appears. It is a caps-only bitmap
 * face, so lowercase is faked by setting the x smaller, which is what makes it read
 * as "xCorp" rather than "XCORP". There is no trailing s any more — the name
 * lost it, and with it the third span. Everything else in the
 * interface uses Geist, because m42 stops being charming the moment it has to
 * carry a sentence.
 */
function Wordmark({ size = 'lg' }: { size?: 'lg' | 'sm' }) {
  const big = size === 'lg' ? 'wm-42' : 'wm-18'
  const small = size === 'lg' ? 'wm-20' : 'wm-9'
  return (
    <span className="wordmark inline-flex items-baseline leading-none">
      <span className={small}>X</span>
      <span className={big}>CORP</span>
    </span>
  )
}

function WalletMenu() {
  const { wallets, address, connecting, error, connect, disconnect } = useWallet()
  const [open, setOpen] = useState(false)
  const navigate = useNavigate()
  // Called here rather than inside the collapsed menu, and that placement is
  // load-bearing: this hook is what starts `initAuth`, which restores a stored
  // session and completes an X redirect. Inside the dropdown it would only run
  // once somebody opened it, so a sign-in that landed on any route other than
  // /profile would sit uncompleted until they went looking for it.

  useEffect(() => {
    if (!open) return
    const close = () => setOpen(false)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [open])

  const go = (path: string) => {
    setOpen(false)
    navigate(path)
  }

  return (
    <div className="relative" onClick={(e) => e.stopPropagation()}>
      <button
        onClick={() => setOpen((v) => !v)}
        disabled={connecting}
        className="ui ui-11 flex h-10 items-center gap-2 bg-ink px-5 text-paper transition-colors hover:bg-ink-mute disabled:opacity-50"
      >
        {/* An address is data, not a label — mono keeps its case and shape. */}
        <span className={address ? 'mono normal-case tracking-normal' : ''}>
          {connecting ? 'Connecting…' : address ? shortAddress(address, 4, 4) : 'Connect'}
        </span>
        <span className="text-[8px] leading-none opacity-70">▼</span>
      </button>

      {open ? (
        <div className="absolute right-0 top-full z-50 mt-1 w-60 border border-ink bg-paper">
          {address ? (
            <>
              <div className="bg-ink px-3 py-2">
                <span className="mono text-paper">{shortAddress(address, 6, 6)}</span>
              </div>
              <MenuItem onClick={() => go('/profile')}>Profile</MenuItem>
              <MenuItem
                onClick={() => {
                  disconnect()
                  setOpen(false)
                }}
              >
                Disconnect
              </MenuItem>
            </>
          ) : (
            <>
              <div className="bg-ink px-3 py-2">
                <span className="ui ui-10 text-paper">Select Wallet</span>
              </div>
              {wallets.length === 0 ? (
                <div className="px-3 py-3 text-[10px] leading-relaxed text-ink-mute">
                  No EVM wallet detected. Install{' '}
                  <a className="underline" href="https://metamask.io/" target="_blank" rel="noreferrer noopener">
                    MetaMask
                  </a>{' '}
                  or Rabby, then reload.
                </div>
              ) : (
                wallets.map((w) => (
                  <button
                    key={w.name}
                    onClick={() => {
                      void connect(w.name)
                      setOpen(false)
                    }}
                    className="flex w-full items-center gap-2 border-b border-rule px-3 py-2.5 text-left text-[11px] last:border-b-0 hover:bg-wash"
                  >
                    {w.icon ? <img src={w.icon} alt="" className="h-4 w-4" /> : null}
                    {w.name}
                  </button>
                ))
              )}
              {error ? <div className="border-t border-rule px-3 py-2 text-[10px] text-t4">{error}</div> : null}
            </>
          )}
        </div>
      ) : null}
    </div>
  )
}

/**
 * Whether the connected wallet carries a verified X handle, shown as one line in
 * the wallet menu.
 *
 * Read-only on purpose. Linking is a flow with six outcomes and a wallet
 * signature in the middle of it; a dropdown is the wrong place for that, and a
 * second entry point would be a second place for the states to be handled
 * differently. This says where you stand and the Profile page below does the
 * work.
 *
 * Renders NOTHING when auth is unconfigured. A build with no Supabase project
 * cannot verify anybody, and a row reading "Not linked" in that build would be
 * describing a wallet rather than the build — an accusation aimed at the wrong
 * party.
 */
function MenuItem({ children, onClick }: { children: React.ReactNode; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className="ui ui-10 block w-full border-b border-rule px-3 py-2.5 text-left text-ink transition-colors last:border-b-0 hover:bg-ink hover:text-paper"
    >
      {children}
    </button>
  )
}

function Header() {
  // Started here because the header renders on every route, so the config poll
  // begins on first paint no matter where a visitor lands. Without a call at
  // this level, a page that does not itself read config (Overview, Marketplace)
  // would never start it, and the mint gate would then be deciding from an
  // unloaded snapshot the moment someone navigated to /mint.
  useRuntimeConfig()
  const tabs = TABS

  return (
    <header className="sticky top-0 z-40 border-b border-ink bg-paper">
      {/* py is load-bearing: without it the wordmark's top pixel row clips
          against the viewport edge. */}
      <div className="mx-auto flex max-w-[1440px] items-center gap-0 px-8 py-5">
        <div className="flex shrink-0 flex-col items-start pr-8">
          <Link to="/" aria-label="xAGENTS home">
            <Wordmark />
          </Link>
          <PoweredBy />
        </div>

        <div className="h-9 w-px shrink-0 bg-ink/20" />

        <nav className="flex flex-1 items-center gap-1.5 overflow-x-auto scrollbar-thin pl-8">
          {tabs.map((tab) => (
            <NavLink
              key={tab.to}
              to={tab.to}
              end={tab.end}
              className={({ isActive }) =>
                `ui ui-11 whitespace-nowrap px-3.5 py-2.5 transition-colors ${
                  tab.keepCase ? 'keep-case' : ''
                } ${isActive ? 'bg-ink text-paper' : 'text-ink hover:bg-wash'}`
              }
            >
              {tab.label}
            </NavLink>
          ))}
        </nav>

        <div className="flex shrink-0 items-center gap-3 pl-6">
          <WalletMenu />
          <XButton />
        </div>
      </div>
    </header>
  )
}

/**
 * The attribution line under the wordmark.
 *
 * This replaced a full status bar, which also carried the price-feed health
 * indicator. Dropping that signal outright would mean a silently stale tape, so
 * the degraded state surfaces here instead — and only when degraded. A healthy
 * feed says nothing extra, which is the whole point of removing the bar.
 */
function PoweredBy() {
  const prices = usePrices()
  const stale = prices.source !== 'live'

  return (
    <span className="mt-1.5 flex items-center gap-2 whitespace-nowrap text-[13px] font-medium leading-none text-ink">
      Powered by xStocks
      {stale ? (
        <span className="ui ui-10 border border-ink px-1 py-0.5 leading-none" title="Live price feed unreachable — showing captured reference prices">
          Cached
        </span>
      ) : null}
    </span>
  )
}

function Footer() {
  return (
    <footer className="mt-12 border-t border-ink">
      <div className="mx-auto max-w-[1440px] px-6 py-8">
        <Wordmark size="sm" />
        <p className="mt-3 max-w-2xl text-[11px] leading-relaxed text-ink-mute">
          A new NFT standard. Every xployee is assigned desks named after tokenized equities held on
          Robinhood Chain. Hold $XAS, hire one, and take your place on xNET.
        </p>
        {/* This paragraph used to say every balance, hire and yield figure on the
            site was simulated. Two thirds of that is no longer true — a mint is a
            real transfer and ownership is read back off the chain — and leaving
            it would have been inaccurate in the other direction. What has NOT
            changed is the yield model, so that is the part the sentence keeps. */}
        <p className="mt-3 max-w-2xl text-[10px] leading-relaxed text-ink-faint">
          Mints are real Robinhood Chain transfers and ownership is verified on chain. Token addresses
          and prices are live. APY, accrual and per-epoch figures are the collection's own model —
          they are a property of the artwork, not a distribution, and nothing here pays out. No
          on-chain program is deployed and xCorp are not an investment product.
        </p>
      </div>
    </footer>
  )
}

/** The market tape, directly under the status bar — always visible, like a desk. */
function Tape() {
  const prices = usePrices()
  return <TickerTape prices={prices.bySymbol} change24h={prices.change24h} />
}

export function Layout() {
  return (
    <div className="min-h-screen bg-paper">
      <Header />
      <Tape />
      <main className="mx-auto max-w-[1440px] px-6 py-6">
        <Outlet />
      </main>
      <Footer />
    </div>
  )
}
