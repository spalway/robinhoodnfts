import { useQuery } from '@tanstack/react-query'
import { cachedFallback, fetchPrices, type PriceMap } from './prices'

/**
 * Live xStock prices, polled.
 *
 * fetchPrices never throws, so this query has no error state to render — a
 * failed fetch simply resolves to the cached map and the status bar says so.
 */
export function usePrices(): PriceMap {
  const { data } = useQuery<PriceMap>({
    queryKey: ['prices'],
    queryFn: ({ signal }) => fetchPrices(signal),
    refetchInterval: 30_000,
    staleTime: 25_000,
  })

  // No error branch to handle: fetchPrices resolves to the cached map on failure,
  // and this covers the first render before the query settles.
  return data ?? cachedFallback()
}
