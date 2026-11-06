import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export type MonthlyBudget = {
  id: string
  space_id: string
  year: number
  month: number
  amount: string | number
  created_by: string
  created_at: string
  updated_at: string
}

type BudgetState = {
  budget: MonthlyBudget | null
  isLoading: boolean
  error: string | null
}

function getPeriod(monthValue: string) {
  const [year, month] = monthValue.split('-').map(Number)
  return { year, month }
}

export function useBudget(spaceId: string | null, monthValue: string) {
  const [state, setState] = useState<BudgetState>({ budget: null, isLoading: true, error: null })
  const [requestVersion, setRequestVersion] = useState(0)
  const { year, month } = getPeriod(monthValue)

  useEffect(() => {
    let active = true
    const load = async () => {
      if (!spaceId) {
        if (active) setState({ budget: null, isLoading: false, error: null })
        return
      }
      if (!supabase) {
        if (active) setState({ budget: null, isLoading: false, error: 'No se pudo conectar con Supabase.' })
        return
      }

      if (active) setState({ budget: null, isLoading: true, error: null })
      const { data, error } = await supabase.from('budgets').select('id, space_id, year, month, amount, created_by, created_at, updated_at').eq('space_id', spaceId).eq('year', year).eq('month', month).maybeSingle()
      if (!active) return
      if (error) {
        setState({ budget: null, isLoading: false, error: 'No pudimos cargar el presupuesto de este período.' })
        return
      }
      setState({ budget: data as MonthlyBudget | null, isLoading: false, error: null })
    }
    void load()
    return () => { active = false }
  }, [month, requestVersion, spaceId, year])

  const refresh = useCallback(() => setRequestVersion((version) => version + 1), [])

  const saveBudget = useCallback(async (amount: number) => {
    if (!supabase || !spaceId) return 'Selecciona un espacio antes de configurar el presupuesto.'
    if (!Number.isFinite(amount) || amount <= 0) return 'Ingresa un presupuesto mayor que cero.'

    if (state.budget) {
      const { data, error } = await supabase.from('budgets').update({ amount }).eq('id', state.budget.id).select('id')
      if (error || !data?.length) return 'No pudimos actualizar el presupuesto. Es posible que ya no tengas permiso.'
    } else {
      const { error } = await supabase.from('budgets').insert({ space_id: spaceId, year, month, amount })
      if (error?.code === '23505') {
        refresh()
        return 'El presupuesto ya fue configurado por otro miembro. Inténtalo nuevamente para actualizarlo.'
      }
      if (error) return 'No pudimos configurar el presupuesto. Inténtalo nuevamente.'
    }
    refresh()
    return null
  }, [month, refresh, spaceId, state.budget, year])

  const deleteBudget = useCallback(async () => {
    if (!supabase || !state.budget) return 'No hay presupuesto para eliminar.'
    const { data, error } = await supabase.from('budgets').delete().eq('id', state.budget.id).select('id')
    if (error || !data?.length) return 'No pudimos eliminar el presupuesto. Es posible que ya no tengas permiso.'
    refresh()
    return null
  }, [refresh, state.budget])

  return { ...state, refresh, saveBudget, deleteBudget }
}
