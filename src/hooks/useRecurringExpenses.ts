import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

export type RecurringExpense = { id: string; space_id: string; name: string; planned_amount: string | number; due_day: number; is_active: boolean; amount_mode: 'fixed' | 'variable'; created_by: string; created_at: string; updated_at: string }
export type RecurringExpensePayment = { id: string; recurring_expense_id: string; year: number; month: number; transaction_id: string; linked_by: string; linked_at: string }
export type RecurringPaymentPayload = { recurring_expense_id: string; amount_cents: string; category_id: string; occurred_on: string; idempotency_key: string; description?: string }
type RecurringState = { spaceId: string | null; expenses: RecurringExpense[]; payments: RecurringExpensePayment[]; isLoading: boolean; error: string | null }

function getPeriod(value: string) { const [year, month] = value.split('-').map(Number); return { year, month } }

export function useRecurringExpenses(spaceId: string | null, monthValue: string) {
  const [state, setState] = useState<RecurringState>({ spaceId: null, expenses: [], payments: [], isLoading: true, error: null })
  const [isRecordingPayments, setIsRecordingPayments] = useState(false)
  const requestRef = useRef(0)
  const { year, month } = getPeriod(monthValue)

  const reload = useCallback(async () => {
    const requestId = ++requestRef.current
    const isCurrent = () => requestId === requestRef.current
    if (!spaceId) { if (isCurrent()) setState({ spaceId: null, expenses: [], payments: [], isLoading: false, error: null }); return false }
    if (!supabase) { if (isCurrent()) setState({ spaceId, expenses: [], payments: [], isLoading: false, error: 'No se pudo conectar con Supabase.' }); return false }

    setState((current) => ({ ...current, spaceId, expenses: [], payments: [], isLoading: true, error: null }))
    const { data: expenseData, error: expenseError } = await supabase.from('recurring_expenses').select('id, space_id, name, planned_amount, due_day, is_active, amount_mode, created_by, created_at, updated_at').eq('space_id', spaceId).order('due_day').order('name')
    if (!isCurrent()) return false
    if (expenseError) {
      const migrationMissing = /amount_mode/i.test(expenseError.message)
      setState({ spaceId, expenses: [], payments: [], isLoading: false, error: migrationMissing ? 'La actualización de obligaciones aún no está aplicada en la base de datos.' : 'No pudimos cargar las obligaciones mensuales.' })
      return false
    }

    const expenses = (expenseData ?? []) as RecurringExpense[]
    const ids = expenses.map((expense) => expense.id)
    const { data: paymentData, error: paymentError } = ids.length
      ? await supabase.from('recurring_expense_payments').select('id, recurring_expense_id, year, month, transaction_id, linked_by, linked_at').in('recurring_expense_id', ids).eq('year', year).eq('month', month)
      : { data: [], error: null }
    if (!isCurrent()) return false
    if (paymentError) { setState({ spaceId, expenses: [], payments: [], isLoading: false, error: 'No pudimos cargar los pagos vinculados.' }); return false }
    setState({ spaceId, expenses, payments: (paymentData ?? []) as RecurringExpensePayment[], isLoading: false, error: null })
    return true
  }, [month, spaceId, year])

  useEffect(() => {
    const load = () => { void reload() }
    load()
    return () => { requestRef.current += 1 }
  }, [reload])
  const refresh = useCallback(() => { void reload() }, [reload])
  const createExpense = useCallback(async (input: { name: string; planned_amount: number; due_day: number; is_active?: boolean; amount_mode: 'fixed' | 'variable' }) => {
    if (!supabase || !spaceId) return 'Selecciona un espacio antes de crear una obligación.'
    const { error } = await supabase.from('recurring_expenses').insert({ space_id: spaceId, ...input })
    if (error) return 'No pudimos crear la obligación. Revisa los datos e inténtalo nuevamente.'
    refresh(); return null
  }, [refresh, spaceId])
  const updateExpense = useCallback(async (id: string, input: { name: string; planned_amount: number; due_day: number; is_active: boolean; amount_mode: 'fixed' | 'variable' }) => {
    if (!supabase) return 'No pudimos actualizar la obligación.'
    const { data, error } = await supabase.from('recurring_expenses').update(input).eq('id', id).select('id')
    if (error || !data?.length) return 'No pudimos actualizar la obligación. Es posible que ya no tengas permiso.'
    refresh(); return null
  }, [refresh])
  const linkPayment = useCallback(async (recurringExpenseId: string, transactionId: string) => {
    if (!supabase) return 'No pudimos vincular el pago.'
    const { error } = await supabase.from('recurring_expense_payments').insert({ recurring_expense_id: recurringExpenseId, year, month, transaction_id: transactionId })
    if (error) return 'No pudimos vincular el gasto. Verifica que sea del mismo espacio y período.'
    refresh(); return null
  }, [month, refresh, year])
  const unlinkPayment = useCallback(async (paymentId: string) => {
    if (!supabase) return 'No pudimos desvincular el pago.'
    const { data, error } = await supabase.from('recurring_expense_payments').delete().eq('id', paymentId).select('id')
    if (error || !data?.length) return 'No pudimos desvincular el pago. Es posible que ya no tengas permiso.'
    refresh(); return null
  }, [refresh])
  const recordPayments = useCallback(async (payments: RecurringPaymentPayload[]) => {
    if (!supabase) return 'No pudimos registrar los pagos.'
    setIsRecordingPayments(true)
    try {
      const { error } = await supabase.rpc('record_recurring_expense_payments', { p_payments: payments })
      if (error) {
        const migrationMissing = /could not find the function|does not exist/i.test(error.message)
        return migrationMissing
          ? 'La función de pagos aún no está aplicada en la base de datos.'
          : 'No pudimos registrar los pagos. Revisa los importes, categorías y fechas e inténtalo nuevamente.'
      }
      return null
    } catch {
      return 'No pudimos registrar los pagos. Revisa la conexión e inténtalo nuevamente.'
    } finally {
      setIsRecordingPayments(false)
    }
  }, [])

  const isCurrentSpace = state.spaceId === spaceId
  return { ...state, expenses: isCurrentSpace ? state.expenses : [], payments: isCurrentSpace ? state.payments : [], isLoading: state.isLoading || !isCurrentSpace, isRecordingPayments, refresh, reload, createExpense, updateExpense, linkPayment, unlinkPayment, recordPayments }
}
