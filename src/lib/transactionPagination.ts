export type TransactionPage<T> = {
  data: T[] | null
  count: number | null
  error: unknown
}

export async function fetchAllTransactionPages<T>(
  fetchPage: (from: number, to: number, includeCount: boolean) => Promise<TransactionPage<T>>,
  isCurrent: () => boolean,
  pageSize = 500,
) {
  const records: T[] = []
  let offset = 0
  let expectedCount: number | null = null

  while (isCurrent()) {
    const page = await fetchPage(offset, offset + pageSize - 1, records.length === 0)
    if (!isCurrent()) return null
    if (page.error) throw page.error

    const rows = page.data ?? []
    if (expectedCount === null && page.count !== null) expectedCount = page.count
    records.push(...rows)

    if ((expectedCount !== null && records.length >= expectedCount) || rows.length < pageSize) return records
    offset += rows.length
  }

  return null
}
