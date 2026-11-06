import type { FinancialTransaction } from '../hooks/useTransactions'

export type MonthlySummary = {
  incomeCents: bigint
  expenseCents: bigint
  balanceCents: bigint
}

export type BudgetProgress = {
  budgetCents: bigint
  expenseCents: bigint
  remainingCents: bigint
  exceededCents: bigint
  percentageBasisPoints: bigint
}

export function getLocalMonthValue(date = new Date()) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`
}

export function toCents(value: string | number) {
  const match = String(value).trim().match(/^(-?)(\d+)(?:\.(\d{1,2}))?$/)
  if (!match) return 0n
  const [, sign, whole, decimal = ''] = match
  const cents = BigInt(whole) * 100n + BigInt(decimal.padEnd(2, '0'))
  return sign === '-' ? -cents : cents
}

export function summarizeMonth(transactions: FinancialTransaction[], month: string): MonthlySummary {
  let incomeCents = 0n
  let expenseCents = 0n
  for (const transaction of transactions) {
    if (!transaction.occurred_on.startsWith(month)) continue
    if (transaction.transaction_type === 'income') incomeCents += toCents(transaction.amount)
    else expenseCents += toCents(transaction.amount)
  }
  return { incomeCents, expenseCents, balanceCents: incomeCents - expenseCents }
}

export function formatPen(cents: bigint) {
  const sign = cents < 0n ? '-' : ''
  const absolute = cents < 0n ? -cents : cents
  const whole = (absolute / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return `${sign}S/ ${whole}.${(absolute % 100n).toString().padStart(2, '0')}`
}

export function calculateBudgetProgress(budgetAmount: string | number, expenseCents: bigint): BudgetProgress {
  const budgetCents = toCents(budgetAmount)
  const remainingCents = budgetCents - expenseCents
  return {
    budgetCents,
    expenseCents,
    remainingCents,
    exceededCents: remainingCents < 0n ? -remainingCents : 0n,
    percentageBasisPoints: budgetCents > 0n ? (expenseCents * 10000n) / budgetCents : 0n,
  }
}

export function formatPercent(basisPoints: bigint) {
  return `${basisPoints / 100n}.${(basisPoints % 100n).toString().padStart(2, '0')}%`
}
