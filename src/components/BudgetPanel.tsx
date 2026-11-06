import { useState, type FormEvent } from 'react'
import type { BudgetProgress } from '../lib/financialSummary'
import { formatPen, formatPercent } from '../lib/financialSummary'

type BudgetPanelProps = {
  budgetAmount: string | number | null
  progress: BudgetProgress | null
  isLoading: boolean
  error: string | null
  compact?: boolean
  onRetry: () => void
  onSave: (amount: number) => Promise<string | null>
  onDelete: () => Promise<string | null>
}

function BudgetPanel({ budgetAmount, progress, isLoading, error, compact = false, onRetry, onSave, onDelete }: BudgetPanelProps) {
  const [editing, setEditing] = useState(false)
  const [amount, setAmount] = useState(budgetAmount ? String(budgetAmount) : '')
  const [isSaving, setIsSaving] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setIsSaving(true)
    setMessage(null)
    const result = await onSave(Number(amount.replace(',', '.')))
    setIsSaving(false)
    if (result) { setMessage(result); return }
    setEditing(false)
    setMessage('Presupuesto guardado correctamente.')
  }

  const remove = async () => {
    if (isSaving || !window.confirm('¿Eliminar el presupuesto de este período?')) return
    setIsSaving(true)
    setMessage(null)
    const result = await onDelete()
    setIsSaving(false)
    setMessage(result ?? 'Presupuesto eliminado.')
  }

  if (isLoading) return <div className="budget-card pending-card">Cargando presupuesto…</div>
  if (error) return <div className="budget-card pending-card">{error} <button className="text-button" onClick={onRetry}>Reintentar</button></div>
  if (!budgetAmount || !progress) return <div className="budget-card pending-card"><strong>Presupuesto no configurado</strong><p>Configura un límite global para este mes.</p><button className="text-button" onClick={() => { setAmount(''); setEditing(true) }}>Configurar presupuesto</button>{editing && <BudgetForm amount={amount} isSaving={isSaving} onChange={setAmount} onCancel={() => setEditing(false)} onSubmit={submit} />}{message && <p className="budget-message">{message}</p>}</div>

  const width = progress.percentageBasisPoints >= 10000n ? 100 : Number(progress.percentageBasisPoints) / 100
  return <div className={`budget-card ${compact ? 'budget-compact' : ''}`}><div className="budget-title"><span>Presupuesto del mes</span><strong>{formatPen(progress.expenseCents)} <small>de {formatPen(progress.budgetCents)}</small></strong></div><div className="progress"><span style={{ width: `${width}%` }} /></div><div className="budget-foot"><span>{formatPercent(progress.percentageBasisPoints)} usado</span><span className={progress.remainingCents < 0n ? 'budget-over' : ''}>{progress.remainingCents < 0n ? `Excedente: ${formatPen(progress.exceededCents)}` : `${formatPen(progress.remainingCents)} disponible`}</span></div><div className="budget-actions"><button className="text-button" onClick={() => { setAmount(String(budgetAmount)); setEditing(true) }}>Modificar</button><button className="text-button danger" onClick={remove} disabled={isSaving}>Eliminar</button></div>{editing && <BudgetForm amount={amount} isSaving={isSaving} onChange={setAmount} onCancel={() => setEditing(false)} onSubmit={submit} />}{message && <p className="budget-message">{message}</p>}</div>
}

function BudgetForm({ amount, isSaving, onChange, onCancel, onSubmit }: { amount: string; isSaving: boolean; onChange: (value: string) => void; onCancel: () => void; onSubmit: (event: FormEvent<HTMLFormElement>) => void }) {
  return <form className="budget-form" onSubmit={onSubmit}><label>Monto mensual<input value={amount} onChange={(event) => onChange(event.target.value)} inputMode="decimal" placeholder="0.00" autoFocus disabled={isSaving} /></label><div><button type="button" onClick={onCancel} disabled={isSaving}>Cancelar</button><button type="submit" disabled={isSaving}>{isSaving ? 'Guardando…' : 'Guardar'}</button></div></form>
}

export default BudgetPanel
