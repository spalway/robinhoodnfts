import { Routes, Route } from 'react-router-dom'
import { Layout } from './components/Layout'
import { Overview } from './pages/Overview'
import { Mint } from './pages/Mint'
import { XNet } from './pages/XNet'
import { Profile } from './pages/Profile'
import { WalletSheet } from './pages/WalletSheet'
import { XployeeSheet } from './pages/XployeeSheet'
import { NotFound } from './pages/NotFound'

/**
 * Four routes and two detail views. That is the whole app.
 *
 * It used to carry a marketplace, a portfolio, a payments queue, a transactions
 * ledger, an operator payout desk, an admin console, a token page and a docs
 * site — every one of them rendering numbers that no on-chain event had ever
 * produced. They are gone rather than emptied: a page that renders invented
 * trades is not fixed by having zero of them, because the machinery to invent
 * them is still sitting there waiting for someone to switch it back on.
 *
 * What is left is the part that is real. A landing page showing unminted art, a
 * mint that moves tokens and issues a serial, a leaderboard of who actually
 * holds what, and a profile.
 */
export function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Overview />} />
        <Route path="mint" element={<Mint />} />
        <Route path="xnet" element={<XNet />} />
        <Route path="profile" element={<Profile />} />
        <Route path="wallet/:address" element={<WalletSheet />} />
        <Route path="xployee/:id" element={<XployeeSheet />} />
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  )
}
