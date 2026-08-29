import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Panel, Empty } from '../components/ui'
import { CrewView } from '../components/CrewView'
import { useWallet } from '../lib/wallet'
import { fetchWalletPage, isBackendError, type WalletPage } from '../lib/backend'

/**
 * The connected wallet's own page.
 *
 * The same CrewView xNET links to, pointed at whoever is connected. There is
 * nothing editable here yet: a handle has to be proved with a signature from the
 * wallet that owns it, and until that exists an editable field would let anybody
 * claim anybody's name. See section 4 of supabase/XCORP-CORE.sql.
 */
export function Profile() {
  const { address } = useWallet()

  const [page, setPage] = useState<WalletPage | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!address) {
      setPage(null)
      return
    }
    let live = true
    setPage(null)
    setError(null)
    void fetchWalletPage(address).then((result) => {
      if (!live) return
      if (isBackendError(result)) setError(result.message)
      else setPage(result)
    })
    return () => {
      live = false
    }
  }, [address])

  if (!address) {
    return (
      <Panel title="Profile">
        <p className="text-[11px] leading-relaxed text-ink-mute">
          Connect an EVM wallet from the header to see your crew. Connecting is read-only —
          nothing is signed, and nothing leaves your wallet until you mint.
        </p>
        <div className="mt-4">
          <Link to="/mint" className="ui ui-10 underline">
            Go to mint →
          </Link>
        </div>
      </Panel>
    )
  }

  if (error) return <Empty title="Could not load your profile">{error}</Empty>
  if (!page) return <Empty title="Loading…" />

  return <CrewView page={page} own />
}
