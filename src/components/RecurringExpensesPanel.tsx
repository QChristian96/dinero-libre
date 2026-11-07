import { useRef, useState, type FormEvent } from 'react'
import { formatPen, toCents } from '../lib/financialSummary'
import { getRecurringDueDate, getRecurringStatus } from '../lib/recurringExpenses'
import type { RecurringExpense, RecurringExpensePayment, RecurringPaymentPayload } from '../hooks/useRecurringExpenses'
import type { Category, FinancialTransaction } from '../hooks/useTransactions'

type AmountMode = 'fixed' | 'variable'

type PaymentDraft = {
  amount: string
  categoryId: string
  occurredOn: string
  idempotencyKey: string
  description: string
}

type ExpenseInput = {
  name: string
  planned_amount: number
  due_day: number
  is_active: boolean
  amount_mode: AmountMode
}

type RecurringExpensesPanelProps = {
  expenses: RecurringExpense[]
  payments: RecurringExpensePayment[]
  transactions: FinancialTransaction[]
  categories: Category[]
  month: string
  isLoading: boolean
  error: string | null
  isRecordingPayments: boolean
  onRetry: () => void
  onCreate: (input: ExpenseInput) => Promise<string | null>
  onUpdate: (id: string, input: ExpenseInput) => Promise<string | null>
  onLink: (expenseId: string, transactionId: string) => Promise<string | null>
  onUnlink: (paymentId: string) => Promise<string | null>
  onRecordPayments: (payments: RecurringPaymentPayload[]) => Promise<string | null>
  onPaymentsRecorded: () => Promise<boolean>
}

const CATEGORY_HINTS: Array<[string, string[]]> = [
  ['vivienda', ['alquiler', 'renta', 'hipoteca', 'departamento', 'casa']],
  ['servicios', ['luz', 'agua', 'internet', 'telefono', 'cable', 'gas', 'electricidad']],
  ['transporte', ['transporte', 'pasaje', 'gasolina', 'combustible', 'taxi', 'bus', 'metro']],
  ['salud', ['salud', 'medico', 'farmacia', 'clinica', 'seguro']],
  ['educacion', ['colegio', 'universidad', 'curso', 'educacion', 'matricula']],
  ['entretenimiento', ['netflix', 'spotify', 'cine', 'juego', 'entretenimiento', 'gimnasio']],
  ['alimentacion', ['comida', 'mercado', 'supermercado', 'alimento', 'restaurante']],
]

function normalizeText(value: string) {
  return value.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
}

function guessCategoryId(name: string, categories: Category[]) {
  const normalized = normalizeText(name)
  for (const [categoryId, keywords] of CATEGORY_HINTS) {
    if (keywords.some((keyword) => normalized.includes(keyword)) && categories.some((category) => category.id === categoryId)) {
      return categoryId
    }
  }
  return categories.find((category) => category.id === 'servicios')?.id ?? categories[0]?.id ?? ''
}

function parseCents(value: string) {
  const normalized = value.trim().replace(',', '.')
  if (!/^\d+(?:\.\d{1,2})?$/.test(normalized)) return null
  const cents = toCents(normalized)
  return cents > 0n ? cents.toString() : null
}

function getMonthBounds(month: string) {
  const [year, monthNumber] = month.split('-').map(Number)
  const lastDay = new Date(year, monthNumber, 0).getDate()
  return {
    min: `${month}-01`,
    max: `${month}-${String(lastDay).padStart(2, '0')}`,
  }
}

function RecurringExpensesPanel({
  expenses,
  payments,
  transactions,
  categories,
  month,
  isLoading,
  error,
  isRecordingPayments,
  onRetry,
  onCreate,
  onUpdate,
  onLink,
  onUnlink,
  onRecordPayments,
  onPaymentsRecorded,
}: RecurringExpensesPanelProps) {
  const [showCreate, setShowCreate] = useState(false)
  const [editing, setEditing] = useState<RecurringExpense | null>(null)
  const [linkingId, setLinkingId] = useState<string | null>(null)
  const [selectedTransactionId, setSelectedTransactionId] = useState('')
  const [selectedExpenseIds, setSelectedExpenseIds] = useState<string[]>([])
  const [drafts, setDrafts] = useState<Record<string, PaymentDraft>>({})
  const [isReviewing, setIsReviewing] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [reviewError, setReviewError] = useState<string | null>(null)
  const [isWorking, setIsWorking] = useState(false)
  const submitRef = useRef(false)

  const [year, monthNumber] = month.split('-').map(Number)
  const isBusy = isWorking || isRecordingPayments
  const paymentByExpense = new Map(payments.map((payment) => [payment.recurring_expense_id, payment]))
  const linkedTransactionIds = new Set(payments.map((payment) => payment.transaction_id))
  const eligibleTransactions = transactions.filter(
    (transaction) => transaction.transaction_type === 'expense' && transaction.occurred_on.startsWith(month) && !linkedTransactionIds.has(transaction.id),
  )
  const expenseCategories = categories.filter((category) => category.transaction_type === 'expense')
  const monthBounds = getMonthBounds(month)
  const selectedExpenses = expenses.filter((expense) => selectedExpenseIds.includes(expense.id))
  const selectedTotal = selectedExpenses.reduce((total, expense) => {
    const draft = drafts[expense.id]
    if (!draft) return total + toCents(expense.planned_amount)
    return total + toCents(draft.amount)
  }, 0n)

  const run = async (operation: () => Promise<string | null>) => {
    if (isBusy) return false
    setIsWorking(true)
    setMessage(null)
    let result: string | null
    try {
      result = await operation()
    } catch {
      result = 'No pudimos guardar los cambios. Inténtalo nuevamente.'
    } finally {
      setIsWorking(false)
    }
    setMessage(result ?? 'Cambios guardados correctamente.')
    return !result
  }

  const toggleExpense = (expense: RecurringExpense) => {
    if (isBusy) return
    setReviewError(null)
    if (selectedExpenseIds.includes(expense.id)) {
      setSelectedExpenseIds((current) => current.filter((id) => id !== expense.id))
      setDrafts((current) => {
        const next = { ...current }
        delete next[expense.id]
        return next
      })
      return
    }

    setSelectedExpenseIds((current) => [...current, expense.id])
    setDrafts((current) => ({
      ...current,
      [expense.id]: {
        amount: String(expense.planned_amount),
        categoryId: guessCategoryId(expense.name, expenseCategories),
        occurredOn: getRecurringDueDate(year, monthNumber, expense.due_day),
        idempotencyKey: crypto.randomUUID(),
        description: `Pago de ${expense.name}`,
      },
    }))
  }

  const updateDraft = (expenseId: string, changes: Partial<PaymentDraft>) => {
    setReviewError(null)
    setDrafts((current) => ({ ...current, [expenseId]: { ...current[expenseId], ...changes } }))
  }

  const confirmBatch = async () => {
    if (isBusy || submitRef.current || !isReviewing) return
    const payload: RecurringPaymentPayload[] = []

    for (const expense of selectedExpenses) {
      const draft = drafts[expense.id]
      const fixed = expense.amount_mode === 'fixed'
      const cents = fixed ? toCents(expense.planned_amount).toString() : draft ? parseCents(draft.amount) : null
      if (!draft || !cents || !draft.categoryId || !draft.occurredOn.startsWith(month)) {
        setReviewError('Revisa importe, categoría y fecha. Cada pago debe pertenecer al mes seleccionado.')
        return
      }
      payload.push({
        recurring_expense_id: expense.id,
        amount_cents: cents,
        category_id: draft.categoryId,
        occurred_on: draft.occurredOn,
        idempotency_key: draft.idempotencyKey,
        description: draft.description.trim() || undefined,
      })
    }

    if (payload.length === 0) {
      setReviewError('Selecciona al menos una obligación para registrar el pago.')
      return
    }

    // Las claves se conservan en el estado del lote: un reintento tras un error
    // reutiliza las mismas claves y la RPC responde de forma idempotente.
    if (new Set(payload.map((item) => item.idempotency_key)).size !== payload.length) {
      setReviewError('El lote contiene claves de idempotencia duplicadas. Vuelve a seleccionar las obligaciones.')
      return
    }

    submitRef.current = true
    setIsWorking(true)
    setReviewError(null)
    try {
      const result = await onRecordPayments(payload)
      if (result) {
        setReviewError(result)
        return
      }

      const synchronized = await onPaymentsRecorded()
      if (!synchronized) {
        setReviewError('Los pagos fueron registrados, pero no pudimos actualizar los datos. Reintenta la actualización sin cambiar el lote.')
        return
      }

      setSelectedExpenseIds([])
      setDrafts({})
      setIsReviewing(false)
      setMessage(`${payload.length} pago${payload.length === 1 ? '' : 's'} registrado${payload.length === 1 ? '' : 's'} y vinculado${payload.length === 1 ? '' : 's'}.`)
    } catch {
      setReviewError('No pudimos confirmar los pagos. Revisa la conexión e inténtalo nuevamente.')
    } finally {
      submitRef.current = false
      setIsWorking(false)
    }
  }

  if (isLoading) return <section className="recurring-panel"><p className="transaction-state">Cargando obligaciones…</p></section>
  if (error) return <section className="recurring-panel"><p className="transaction-state error">{error} <button onClick={onRetry}>Reintentar</button></p></section>

  return (
    <section className="recurring-panel">
      <div className="section-heading">
        <div>
          <p className="eyebrow">GASTOS FIJOS MENSUALES</p>
          <h2>Obligaciones</h2>
        </div>
        <button className="text-button" onClick={() => { setEditing(null); setShowCreate(true) }} disabled={isBusy}>Nueva obligación</button>
      </div>
      <p className="planning-intro">Los montos previstos no se suman a tus gastos reales hasta que registres o vincules un pago.</p>

      {showCreate && (
        <RecurringForm
          title="Nueva obligación"
          onCancel={() => setShowCreate(false)}
          onSubmit={async (input) => {
            const ok = await run(() => onCreate(input))
            if (ok) setShowCreate(false)
          }}
        />
      )}

      {editing && (
        <RecurringForm
          title="Editar obligación"
          initial={editing}
          onCancel={() => setEditing(null)}
          onSubmit={async (input) => {
            const ok = await run(() => onUpdate(editing.id, input))
            if (ok) setEditing(null)
          }}
        />
      )}

      {expenses.length === 0 && !showCreate ? (
        <p className="transaction-state">No hay obligaciones registradas para este espacio.</p>
      ) : (
        <div className="recurring-list">
          {expenses.map((expense) => {
            const payment = paymentByExpense.get(expense.id) ?? null
            const paidTransaction = payment ? transactions.find((transaction) => transaction.id === payment.transaction_id) ?? null : null
            const paidCents = paidTransaction ? toCents(paidTransaction.amount) : null
            const plannedCents = toCents(expense.planned_amount)
            const dueDate = getRecurringDueDate(year, monthNumber, expense.due_day)
            const status = getRecurringStatus(expense.is_active, Boolean(payment), dueDate)
            const canPay = expense.is_active && !payment
            const isSelected = selectedExpenseIds.includes(expense.id)

            return (
              <article className={`recurring-card${isSelected ? ' selected' : ''}`} key={expense.id}>
                <div className="recurring-main">
                  {canPay && (
                    <label className="recurring-check">
                      <input
                        type="checkbox"
                        checked={isSelected}
                        onChange={() => toggleExpense(expense)}
                        disabled={isBusy}
                      />
                      <span className="sr-only">Seleccionar {expense.name} para pagar</span>
                    </label>
                  )}
                  <div className="recurring-info">
                    <strong>
                      {expense.name}
                      <em className={`recurring-mode${expense.amount_mode === 'variable' ? ' variable' : ''}`}>
                        {expense.amount_mode === 'variable' ? 'Variable' : 'Fijo'}
                      </em>
                    </strong>
                    <span>Vence: {new Date(`${dueDate}T12:00:00`).toLocaleDateString('es-PE', { day: 'numeric', month: 'short' })}</span>
                    {paidCents !== null && paidCents !== plannedCents && <span>Previsto: {formatPen(plannedCents)}</span>}
                  </div>
                </div>
                <div className="recurring-amount">
                  <b>{formatPen(paidCents ?? plannedCents)}</b>
                  <small>{payment ? 'Pagado' : 'Previsto'}</small>
                </div>
                <span className={`recurring-status ${status}`}>{status}</span>
                <div className="recurring-actions">
                  <button className="text-button" disabled={isBusy} onClick={() => { setShowCreate(false); setEditing(expense) }}>Editar</button>
                  {expense.is_active && (
                    <button
                      className="text-button"
                      disabled={isBusy}
                      onClick={() => void run(() => onUpdate(expense.id, {
                        name: expense.name,
                        planned_amount: Number(expense.planned_amount),
                        due_day: expense.due_day,
                        is_active: false,
                        amount_mode: expense.amount_mode,
                      }))}
                    >
                      Desactivar
                    </button>
                  )}
                  {payment ? (
                    <button className="text-button danger" disabled={isBusy} onClick={() => void run(() => onUnlink(payment.id))}>Desvincular pago</button>
                  ) : (
                    <button
                      className="text-button"
                      disabled={isBusy}
                      onClick={() => { setLinkingId(expense.id); setSelectedTransactionId('') }}
                    >
                      Vincular gasto existente
                    </button>
                  )}
                </div>
                {linkingId === expense.id && (
                  <div className="payment-link">
                    <select value={selectedTransactionId} onChange={(event) => setSelectedTransactionId(event.target.value)} disabled={isBusy}>
                      <option value="">Selecciona un gasto real</option>
                      {eligibleTransactions.map((transaction) => (
                        <option key={transaction.id} value={transaction.id}>
                          {transaction.description || transaction.categories?.name || 'Gasto'} · {formatPen(toCents(transaction.amount))}
                        </option>
                      ))}
                    </select>
                    <button
                      disabled={!selectedTransactionId || isBusy}
                      onClick={async () => {
                        const ok = await run(() => onLink(expense.id, selectedTransactionId))
                        if (ok) setLinkingId(null)
                      }}
                    >
                      Confirmar vínculo
                    </button>
                    {eligibleTransactions.length === 0 && <small>No hay gastos disponibles de este mes.</small>}
                  </div>
                )}
              </article>
            )
          })}
        </div>
      )}

      {selectedExpenses.length > 0 && !isReviewing && (
        <button
          className="review-payments"
          disabled={isBusy}
          onClick={() => { setReviewError(null); setIsReviewing(true) }}
        >
          Revisar pagos ({selectedExpenses.length}) · {formatPen(selectedTotal)}
        </button>
      )}

      {isReviewing && (
        <section className="payment-review" aria-labelledby="payment-review-title">
          <div className="section-heading">
            <div>
              <p className="eyebrow">REVISIÓN</p>
              <h2 id="payment-review-title">Confirmar pagos</h2>
            </div>
            <button className="text-button" disabled={isBusy} onClick={() => setIsReviewing(false)}>Volver</button>
          </div>
          <p className="payment-review-intro">Puedes ajustar la categoría y la fecha de cada gasto. Los importes fijos no se modifican.</p>

          <div className="payment-review-list">
            {selectedExpenses.map((expense) => {
              const draft = drafts[expense.id]
              if (!draft) return null
              const fixed = expense.amount_mode === 'fixed'
              return (
                <div className="payment-review-row" key={expense.id}>
                  <div className="payment-review-head">
                    <strong>{expense.name}</strong>
                    <em className={`recurring-mode${fixed ? '' : ' variable'}`}>{fixed ? 'Fijo' : 'Variable'}</em>
                  </div>
                  <label>
                    Importe
                    <input
                      value={draft.amount}
                      onChange={(event) => updateDraft(expense.id, { amount: event.target.value })}
                      inputMode="decimal"
                      disabled={fixed || isBusy}
                      aria-label={`Importe de ${expense.name}`}
                    />
                    {fixed && <small>Importe fijo según lo previsto.</small>}
                  </label>
                  <label>
                    Categoría
                    <select
                      value={draft.categoryId}
                      onChange={(event) => updateDraft(expense.id, { categoryId: event.target.value })}
                      disabled={isBusy}
                    >
                      <option value="">Selecciona categoría</option>
                      {expenseCategories.map((category) => (
                        <option key={category.id} value={category.id}>{category.name}</option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Fecha
                    <input
                      type="date"
                      value={draft.occurredOn}
                      min={monthBounds.min}
                      max={monthBounds.max}
                      onChange={(event) => updateDraft(expense.id, { occurredOn: event.target.value })}
                      disabled={isBusy}
                    />
                  </label>
                </div>
              )
            })}
          </div>

          {reviewError && <p className="form-error" role="alert">{reviewError}</p>}

          <div className="payment-review-actions">
            <button className="text-button" disabled={isBusy} onClick={() => setIsReviewing(false)}>Cancelar</button>
            <button
              className="review-payments"
              disabled={isBusy || selectedExpenses.length === 0}
              onClick={() => void confirmBatch()}
            >
              {isBusy ? 'Registrando pagos…' : `Confirmar y registrar ${selectedExpenses.length} pago${selectedExpenses.length === 1 ? '' : 's'}`}
            </button>
          </div>
        </section>
      )}

      {message && <p className="budget-message" role="status">{message}</p>}
    </section>
  )
}

function RecurringForm({
  title,
  initial,
  onCancel,
  onSubmit,
}: {
  title: string
  initial?: RecurringExpense
  onCancel: () => void
  onSubmit: (input: ExpenseInput) => Promise<void>
}) {
  const [name, setName] = useState(initial?.name ?? '')
  const [amount, setAmount] = useState(initial ? String(initial.planned_amount) : '')
  const [day, setDay] = useState(initial ? String(initial.due_day) : '')
  const [amountMode, setAmountMode] = useState<AmountMode>(initial?.amount_mode ?? 'fixed')
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (isSaving) return

    const cents = parseCents(amount)
    const dueDay = Number(day)
    if (!name.trim()) {
      setError('Ingresa un nombre para la obligación.')
      return
    }
    if (!cents) {
      setError('Ingresa un monto previsto mayor que cero, con hasta dos decimales.')
      return
    }
    if (!Number.isInteger(dueDay) || dueDay < 1 || dueDay > 31) {
      setError('El día de vencimiento debe ser un número entero entre 1 y 31.')
      return
    }

    setIsSaving(true)
    setError(null)
    try {
      await onSubmit({
        name: name.trim(),
        planned_amount: Number(cents) / 100,
        due_day: dueDay,
        is_active: initial?.is_active ?? true,
        amount_mode: amountMode,
      })
    } finally {
      setIsSaving(false)
    }
  }

  return (
    <form className="recurring-form" onSubmit={submit}>
      <strong>{title}</strong>
      <input value={name} onChange={(event) => setName(event.target.value)} placeholder="Ej. Internet" maxLength={120} required disabled={isSaving} />
      <div>
        <input value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="Monto previsto" inputMode="decimal" required disabled={isSaving} />
        <input value={day} onChange={(event) => setDay(event.target.value)} placeholder="Día (1-31)" inputMode="numeric" min="1" max="31" required disabled={isSaving} />
      </div>
      <label className="amount-mode">
        Tipo de importe
        <select value={amountMode} onChange={(event) => setAmountMode(event.target.value as AmountMode)} disabled={isSaving}>
          <option value="fixed">Fijo (el pago debe coincidir con lo previsto)</option>
          <option value="variable">Variable (el pago puede diferir)</option>
        </select>
      </label>
      {error && <p className="form-error" role="alert">{error}</p>}
      <footer>
        <button type="button" onClick={onCancel} disabled={isSaving}>Cancelar</button>
        <button type="submit" disabled={isSaving}>{isSaving ? 'Guardando…' : 'Guardar'}</button>
      </footer>
    </form>
  )
}

export default RecurringExpensesPanel
