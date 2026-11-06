import { useMemo } from 'react'
import { calculateFreeMoney, type FreeMoneyResult, type RecurringPayment, type RecurringReservation } from '../lib/freeMoney'
import type { MonthlySummary } from '../lib/financialSummary'

type FreeMoneySource = {
  isLoading: boolean
  error: string | null
}

export function useFreeMoney(
  summary: MonthlySummary,
  recurringExpenses: RecurringReservation[],
  payments: RecurringPayment[],
  savingsAmount: string | number | null,
  monthValue: string,
  sources: FreeMoneySource[],
) {
  const isLoading = sources.some((source) => source.isLoading)
  const error = sources.find((source) => source.error)?.error ?? null
  const result = useMemo<FreeMoneyResult | null>(() => {
    if (isLoading || error) return null
    return calculateFreeMoney(summary, recurringExpenses, payments, monthValue, savingsAmount)
  }, [error, isLoading, monthValue, payments, recurringExpenses, savingsAmount, summary])

  return {
    result,
    status: isLoading ? 'loading' : error ? 'error' : recurringExpenses.length === 0 && payments.length === 0 && savingsAmount === null ? 'empty' : 'ready',
    error,
  }
}
