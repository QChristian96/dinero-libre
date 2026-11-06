import { useState, type FormEvent } from 'react'
import type { Category, FinancialTransaction, TransactionType } from '../hooks/useTransactions'

type TransactionsListProps = {
  transactions: FinancialTransaction[]
  categories: Category[]
  currentUserId: string
  editable?: boolean
  onUpdate: (id: string, values: { transaction_type: TransactionType; amount: number; category_id: string; description: string | null; occurred_on: string }) => Promise<string | null>
  onDelete: (id: string) => Promise<string | null>
}

const formatAmount = (amount: string | number, type: TransactionType) => `${type === 'income' ? '+' : '-'} S/ ${Number(amount).toLocaleString('es-PE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`

function TransactionsList({ transactions, categories, currentUserId, editable = false, onUpdate, onDelete }: TransactionsListProps) {
  const [editing, setEditing] = useState<FinancialTransaction | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const saveEdit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!editing || busyId) return
    const form = new FormData(event.currentTarget)
    const transactionType = form.get('transaction_type') as TransactionType
    setBusyId(editing.id)
    const result = await onUpdate(editing.id, {
      transaction_type: transactionType,
      amount: Number(form.get('amount')),
      category_id: String(form.get('category_id')),
      description: String(form.get('description')).trim() || null,
      occurred_on: String(form.get('occurred_on')),
    })
    setBusyId(null)
    if (result) { setError(result); return }
    setEditing(null)
  }

  const remove = async (id: string) => {
    if (busyId || !window.confirm('¿Eliminar este movimiento? Esta acción no se puede deshacer.')) return
    setBusyId(id)
    setError(null)
    const result = await onDelete(id)
    setBusyId(null)
    if (result) setError(result)
  }

  if (transactions.length === 0) return <p className="transaction-state">Todavía no hay movimientos en este espacio.</p>

  return <div className="transactions">{error && <p className="transaction-state error" role="alert">{error}</p>}{transactions.map((transaction) => {
    const isOwner = transaction.created_by === currentUserId
    if (editing?.id === transaction.id) {
      const compatibleCategories = categories.filter((category) => category.transaction_type === editing.transaction_type)
      return <form className="transaction-edit" key={transaction.id} onSubmit={saveEdit}><select name="transaction_type" defaultValue={editing.transaction_type} onChange={(event) => setEditing((current) => current && { ...current, transaction_type: event.target.value as TransactionType, category_id: '' })} disabled={busyId === transaction.id}><option value="expense">Gasto</option><option value="income">Ingreso</option></select><input name="amount" type="number" min="0.01" step="0.01" defaultValue={editing.amount} required disabled={busyId === transaction.id} /><select name="category_id" value={editing.category_id} onChange={(event) => setEditing((current) => current && { ...current, category_id: event.target.value })} required disabled={busyId === transaction.id}><option value="" disabled>Categoria</option>{compatibleCategories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select><input name="occurred_on" type="date" defaultValue={editing.occurred_on} required disabled={busyId === transaction.id} /><input name="description" defaultValue={editing.description ?? ''} placeholder="Descripción" disabled={busyId === transaction.id} /><div><button type="button" onClick={() => setEditing(null)} disabled={busyId === transaction.id}>Cancelar</button><button type="submit" disabled={!editing.category_id || busyId === transaction.id}>{busyId === transaction.id ? 'Guardando…' : 'Guardar'}</button></div></form>
    }
    return <article className="transaction" key={transaction.id}><span className={`transaction-icon ${transaction.transaction_type === 'income' ? 'income' : 'expense'}`}>{transaction.transaction_type === 'income' ? '↑' : '↓'}</span><div className="transaction-info"><strong>{transaction.description || transaction.categories?.name || 'Movimiento'}</strong><span>{transaction.categories?.name ?? 'Sin categoría'} · {new Date(`${transaction.occurred_on}T12:00:00`).toLocaleDateString('es-PE', { day: 'numeric', month: 'short' })}</span></div><div className="transaction-value"><b className={transaction.transaction_type === 'income' ? 'income' : 'expense'}>{formatAmount(transaction.amount, transaction.transaction_type)}</b>{editable && isOwner && <span><button onClick={() => { setError(null); setEditing(transaction) }}>Editar</button><button onClick={() => void remove(transaction.id)} disabled={busyId === transaction.id}>{busyId === transaction.id ? '…' : 'Eliminar'}</button></span>}</div></article>
  })}</div>
}

export default TransactionsList
