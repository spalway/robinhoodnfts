import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Empty } from '../components/ui'
import { CrewView } from '../components/CrewView'
import { useWallet } from '../lib/wallet'
import { fetchWalletPage, isBackendError, type WalletPage } from '../lib/backend'

/** Any wallet's public page, reached from xNET. */
export function WalletSheet() {
  const { address } = useParams<{ address: string }>()
  const { address: connected } = useWallet()

  const [page, setPage] = useState<WalletPage | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!address) return
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
      <Empty title="No wallet in the URL">
        <Link to="/xnet" className="underline">
          Back to xNET →
        </Link>
      </Empty>
    )
  }

  if (error) return <Empty title="Could not load that wallet">{error}</Empty>
  if (!page) return <Empty title="Loading…" />

  return <CrewView page={page} own={connected === address} />
}
