import { useState, type FormEvent } from 'react'
import { formatPen, toCents } from '../lib/financialSummary'

type MonthlySavingsPanelProps = {
  amount: string | number | null
  isLoading: boolean
  error: string | null
  onRetry: () => void
  onSave: (amount: number) => Promise<string | null>
  onDelete: () => Promise<string | null>
}

function MonthlySavingsPanel({ amount, isLoading, error, onRetry, onSave, onDelete }: MonthlySavingsPanelProps) {
  const [editing, setEditing] = useState(false)
  const [value, setValue] = useState(amount ? String(amount) : '')
  const [isSaving, setIsSaving] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (isSaving) return
    const normalizedValue = value.replace(',', '.')
    if (!/^\d+(?:\.\d{1,2})?$/.test(normalizedValue) || Number(normalizedValue) <= 0) {
      setMessage('Ingresa un monto positivo con un máximo de dos decimales.')
      return
    }
    setIsSaving(true)
    setMessage(null)
    const result = await onSave(Number(normalizedValue))
    setIsSaving(false)
    if (result) { setMessage(result); return }
    setEditing(false)
    setMessage('Reserva mensual guardada.')
  }

  const remove = async () => {
    if (isSaving || !window.confirm('¿Eliminar la reserva de ahorro de este período?')) return
    setIsSaving(true)
    setMessage(null)
    const result = await onDelete()
    setIsSaving(false)
    setMessage(result ?? 'Reserva mensual eliminada.')
  }

  if (isLoading) return <section className="savings-panel"><p className="transaction-state">Cargando reserva mensual…</p></section>
  if (error) return <section className="savings-panel"><p className="transaction-state error">{error} <button onClick={onRetry}>Reintentar</button></p></section>

  return <section className="savings-panel" aria-labelledby="savings-title"><div className="section-heading"><div><p className="eyebrow">AHORRO MENSUAL</p><h2 id="savings-title">Reserva de ahorro</h2></div></div>{amount ? <div className="savings-card"><strong>{formatPen(toCents(amount))}</strong><p>Reserva prevista para este período. No es un gasto real.</p><div><button className="text-button" onClick={() => { setValue(String(amount)); setEditing(true) }} disabled={isSaving}>Modificar</button><button className="text-button danger" onClick={remove} disabled={isSaving}>Eliminar</button></div></div> : <div className="savings-card empty"><strong>Sin reserva configurada</strong><p>Define cuánto quieres reservar este mes, sin afectar tus movimientos.</p><button className="text-button" onClick={() => { setValue(''); setEditing(true) }}>Configurar reserva</button></div>}{editing && <form className="savings-form" onSubmit={submit}><label>Monto a reservar<input value={value} onChange={(event) => setValue(event.target.value)} inputMode="decimal" placeholder="0.00" autoFocus disabled={isSaving} aria-describedby="savings-help" required /></label><small id="savings-help">Debe ser mayor que cero y se guarda con dos decimales.</small><footer><button type="button" onClick={() => setEditing(false)} disabled={isSaving}>Cancelar</button><button type="submit" disabled={isSaving}>{isSaving ? 'Guardando…' : 'Guardar reserva'}</button></footer></form>}{message && <p className="budget-message" role={message.includes('No pudimos') || message.includes('mayor') || message.includes('ya fue') ? 'alert' : 'status'}>{message}</p>}</section>
}

export default MonthlySavingsPanel
