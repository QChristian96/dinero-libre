import type { MonthlySummary } from './financialSummary'
import { toCents } from './financialSummary'

export type RecurringReservation = {
  id: string
  planned_amount: string | number
  is_active: boolean
}

export type RecurringPayment = {
  recurring_expense_id: string
  year: number
  month: number
}

export type FreeMoneyResult = {
  pendingRecurringCents: bigint
  savingsReservedCents: bigint
  freeMoneyCents: bigint
}

export function calculateFreeMoney(
  summary: MonthlySummary,
  recurringExpenses: RecurringReservation[],
  payments: RecurringPayment[],
  monthValue: string,
  savingsAmount: string | number | null,
): FreeMoneyResult {
  const [year, month] = monthValue.split('-').map(Number)
  const paidExpenseIds = new Set(payments.filter((payment) => payment.year === year && payment.month === month).map((payment) => payment.recurring_expense_id))
  const pendingRecurringCents = recurringExpenses.reduce((total, expense) => {
    if (!expense.is_active || paidExpenseIds.has(expense.id)) return total
    return total + toCents(expense.planned_amount)
  }, 0n)
  const savingsReservedCents = savingsAmount === null ? 0n : toCents(savingsAmount)
  return {
    pendingRecurringCents,
    savingsReservedCents,
    freeMoneyCents: summary.incomeCents - summary.expenseCents - pendingRecurringCents - savingsReservedCents,
  }
}
