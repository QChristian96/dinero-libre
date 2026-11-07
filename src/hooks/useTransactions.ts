import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { fetchAllTransactionPages } from '../lib/transactionPagination'

export type TransactionType = 'income' | 'expense'

export type Category = { id: string; name: string; transaction_type: TransactionType }

export type FinancialTransaction = {
  id: string
  space_id: string
  created_by: string
  transaction_type: TransactionType
  amount: string | number
  category_id: string
  description: string | null
  occurred_on: string
  created_at: string
  categories: { name: string } | null
}

export type TransactionInput = Pick<FinancialTransaction, 'transaction_type' | 'amount' | 'category_id' | 'description' | 'occurred_on'> & { idempotency_key: string }

type TransactionState = { spaceId: string | null; categories: Category[]; transactions: FinancialTransaction[]; isLoading: boolean; error: string | null }

export function useTransactions(spaceId: string | null, periodKey = '') {
  const [state, setState] = useState<TransactionState>({ spaceId: null, categories: [], transactions: [], isLoading: true, error: null })
  const requestRef = useRef(0)

  const reload = useCallback(async () => {
    // El período forma parte de la clave de recarga aunque el filtrado se hace
    // sobre el resumen mensual en el cliente.
    void periodKey
    const requestId = ++requestRef.current
    const isCurrent = () => requestId === requestRef.current

    if (!spaceId) {
      if (isCurrent()) setState({ spaceId: null, categories: [], transactions: [], isLoading: false, error: null })
      return false
    }
    if (!supabase) {
      if (isCurrent()) setState({ spaceId, categories: [], transactions: [], isLoading: false, error: 'No se pudo conectar con Supabase.' })
      return false
    }

    const client = supabase
    setState((current) => ({ ...current, spaceId, transactions: [], isLoading: true, error: null }))
    const categoriesPromise = client.from('categories').select('id, name, transaction_type').order('name')
    try {
      const transactionData = await fetchAllTransactionPages(
        async (from, to, includeCount) => await client.from('transactions').select('id, space_id, created_by, transaction_type, amount, category_id, description, occurred_on, created_at, categories(name)', { count: includeCount ? 'exact' : undefined }).eq('space_id', spaceId).order('occurred_on', { ascending: false }).order('created_at', { ascending: false }).order('id', { ascending: false }).range(from, to),
        isCurrent,
      )
      const categoriesResult = await categoriesPromise
      if (!isCurrent()) return false
      if (categoriesResult.error || transactionData === null) {
        setState((current) => ({ ...current, spaceId, transactions: [], isLoading: false, error: 'No pudimos cargar los movimientos de este espacio. Inténtalo nuevamente.' }))
        return false
      }

      const rawTransactions = transactionData as Array<Omit<FinancialTransaction, 'categories'> & { categories: { name: string }[] | null }>
      const transactions = rawTransactions.map((transaction) => ({ ...transaction, categories: Array.isArray(transaction.categories) ? transaction.categories[0] ?? null : transaction.categories }))
      setState({ spaceId, categories: (categoriesResult.data ?? []) as Category[], transactions, isLoading: false, error: null })
      return true
    } catch {
      if (isCurrent()) setState((current) => ({ ...current, spaceId, transactions: [], isLoading: false, error: 'No pudimos cargar los movimientos de este espacio. Inténtalo nuevamente.' }))
      return false
    }
  }, [periodKey, spaceId])

  useEffect(() => {
    const load = () => { void reload() }
    load()
    return () => { requestRef.current += 1 }
  }, [reload])

  const refresh = useCallback(() => { void reload() }, [reload])
  const createTransaction = useCallback(async (input: TransactionInput) => {
    if (!supabase || !spaceId) return 'Selecciona un espacio antes de registrar un movimiento.'
    const { error } = await supabase.from('transactions').insert({ space_id: spaceId, ...input })
    if (error && error.code !== '23505') return 'No pudimos guardar el movimiento. Verifica los datos e inténtalo nuevamente.'
    refresh()
    return null
  }, [refresh, spaceId])

  const updateTransaction = useCallback(async (id: string, values: Pick<TransactionInput, 'transaction_type' | 'amount' | 'category_id' | 'description' | 'occurred_on'>) => {
    if (!supabase) return 'No se pudo actualizar el movimiento.'
    const { data, error } = await supabase.from('transactions').update(values).eq('id', id).select('id')
    if (error || !data?.length) return 'No pudimos actualizar este movimiento. Es posible que ya no tengas permiso.'
    refresh()
    return null
  }, [refresh])

  const deleteTransaction = useCallback(async (id: string) => {
    if (!supabase) return 'No se pudo eliminar el movimiento.'
    const { data, error } = await supabase.from('transactions').delete().eq('id', id).select('id')
    if (error || !data?.length) return 'No pudimos eliminar este movimiento. Es posible que ya no tengas permiso.'
    refresh()
    return null
  }, [refresh])

  const isCurrentSpace = state.spaceId === spaceId
  return { ...state, transactions: isCurrentSpace ? state.transactions : [], isLoading: state.isLoading || !isCurrentSpace, refresh, reload, createTransaction, updateTransaction, deleteTransaction }
}
