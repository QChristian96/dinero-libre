import { useState, type FormEvent } from 'react'
import { formatPen, toCents } from '../lib/financialSummary'
import { getRecurringDueDate, getRecurringStatus } from '../lib/recurringExpenses'
import type { RecurringExpense, RecurringExpensePayment } from '../hooks/useRecurringExpenses'
import type { FinancialTransaction } from '../hooks/useTransactions'

type RecurringExpensesPanelProps = {
  expenses: RecurringExpense[]
  payments: RecurringExpensePayment[]
  transactions: FinancialTransaction[]
  month: string
  isLoading: boolean
  error: string | null
  onRetry: () => void
  onCreate: (input: { name: string; planned_amount: number; due_day: number }) => Promise<string | null>
  onUpdate: (id: string, input: { name: string; planned_amount: number; due_day: number; is_active: boolean }) => Promise<string | null>
  onLink: (expenseId: string, transactionId: string) => Promise<string | null>
  onUnlink: (paymentId: string) => Promise<string | null>
}

function RecurringExpensesPanel({ expenses, payments, transactions, month, isLoading, error, onRetry, onCreate, onUpdate, onLink, onUnlink }: RecurringExpensesPanelProps) {
  const [showCreate, setShowCreate] = useState(false)
  const [editing, setEditing] = useState<RecurringExpense | null>(null)
  const [linkingId, setLinkingId] = useState<string | null>(null)
  const [selectedTransactionId, setSelectedTransactionId] = useState('')
  const [message, setMessage] = useState<string | null>(null)
  const [isWorking, setIsWorking] = useState(false)
  const linkedIds = new Set(payments.map((payment) => payment.transaction_id))
  const eligibleTransactions = transactions.filter((transaction) => transaction.transaction_type === 'expense' && transaction.occurred_on.startsWith(month) && !linkedIds.has(transaction.id))
  const [year, selectedMonth] = month.split('-').map(Number)

  const run = async (operation: () => Promise<string | null>) => {
    if (isWorking) return false
    setIsWorking(true)
    setMessage(null)
    const result = await operation()
    setIsWorking(false)
    setMessage(result ?? 'Cambios guardados correctamente.')
    return !result
  }

  if (isLoading) return <section className="recurring-panel"><p className="transaction-state">Cargando gastos fijos…</p></section>
  if (error) return <section className="recurring-panel"><p className="transaction-state error">{error} <button onClick={onRetry}>Reintentar</button></p></section>

  return <section className="recurring-panel"><div className="section-heading"><div><p className="eyebrow">GASTOS FIJOS MENSUALES</p><h2>Obligaciones</h2></div><button className="text-button" onClick={() => { setEditing(null); setShowCreate(true) }}>Nueva obligación</button></div><p className="planning-intro">Los montos previstos no se suman a tus gastos reales hasta que vincules un movimiento.</p>{showCreate && <RecurringForm title="Nueva obligación" onCancel={() => setShowCreate(false)} onSubmit={async (input) => { const ok = await run(() => onCreate(input)); if (ok) setShowCreate(false) }} />}{editing && <RecurringForm title="Editar obligación" initial={editing} onCancel={() => setEditing(null)} onSubmit={async (input) => { const ok = await run(() => onUpdate(editing.id, { ...input, is_active: editing.is_active })); if (ok) setEditing(null) }} />}{expenses.length === 0 && !showCreate ? <p className="transaction-state">No hay obligaciones registradas para este espacio.</p> : <div className="recurring-list">{expenses.map((expense) => {
    const payment = payments.find((item) => item.recurring_expense_id === expense.id) ?? null
    const dueDate = getRecurringDueDate(year, selectedMonth, expense.due_day)
    const status = getRecurringStatus(expense.is_active, Boolean(payment), dueDate)
    return <article className="recurring-card" key={expense.id}><div><strong>{expense.name}</strong><span>Vence: {new Date(`${dueDate}T12:00:00`).toLocaleDateString('es-PE', { day: 'numeric', month: 'short' })}</span></div><b>{formatPen(toCents(expense.planned_amount))}</b><span className={`recurring-status ${status}`}>{status}</span><div className="recurring-actions"><button className="text-button" disabled={isWorking} onClick={() => { setShowCreate(false); setEditing(expense) }}>Editar</button>{expense.is_active && <button className="text-button" disabled={isWorking} onClick={() => void run(() => onUpdate(expense.id, { name: expense.name, planned_amount: Number(expense.planned_amount), due_day: expense.due_day, is_active: false }))}>Desactivar</button>}{payment ? <button className="text-button danger" disabled={isWorking} onClick={() => void run(() => onUnlink(payment.id))}>Desvincular pago</button> : <button className="text-button" disabled={isWorking} onClick={() => { setLinkingId(expense.id); setSelectedTransactionId('') }}>Vincular gasto</button>}</div>{linkingId === expense.id && <div className="payment-link"><select value={selectedTransactionId} onChange={(event) => setSelectedTransactionId(event.target.value)} disabled={isWorking}><option value="">Selecciona un gasto real</option>{eligibleTransactions.map((transaction) => <option key={transaction.id} value={transaction.id}>{transaction.description || transaction.categories?.name || 'Gasto'} · {formatPen(toCents(transaction.amount))}</option>)}</select><button disabled={!selectedTransactionId || isWorking} onClick={async () => { const ok = await run(() => onLink(expense.id, selectedTransactionId)); if (ok) setLinkingId(null) }}>Confirmar vínculo</button>{eligibleTransactions.length === 0 && <small>No hay gastos disponibles de este mes.</small>}</div>}</article>
  })}</div>}{message && <p className="budget-message">{message}</p>}</section>
}

function RecurringForm({ title, initial, onCancel, onSubmit }: { title: string; initial?: RecurringExpense; onCancel: () => void; onSubmit: (input: { name: string; planned_amount: number; due_day: number }) => Promise<void> }) {
  const [name, setName] = useState(initial?.name ?? '')
  const [amount, setAmount] = useState(initial ? String(initial.planned_amount) : '')
  const [day, setDay] = useState(initial ? String(initial.due_day) : '')
  const [isSaving, setIsSaving] = useState(false)
  const submit = async (event: FormEvent<HTMLFormElement>) => { event.preventDefault(); setIsSaving(true); await onSubmit({ name: name.trim(), planned_amount: Number(amount.replace(',', '.')), due_day: Number(day) }); setIsSaving(false) }
  return <form className="recurring-form" onSubmit={submit}><strong>{title}</strong><input value={name} onChange={(event) => setName(event.target.value)} placeholder="Ej. Internet" maxLength={120} required disabled={isSaving} /><div><input value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="Monto previsto" inputMode="decimal" required disabled={isSaving} /><input value={day} onChange={(event) => setDay(event.target.value)} placeholder="Día (1-31)" inputMode="numeric" min="1" max="31" required disabled={isSaving} /></div><footer><button type="button" onClick={onCancel} disabled={isSaving}>Cancelar</button><button type="submit" disabled={isSaving}>{isSaving ? 'Guardando…' : 'Guardar'}</button></footer></form>
}

export default RecurringExpensesPanel
