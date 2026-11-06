import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export type MonthlySaving = {
  id: string
  space_id: string
  year: number
  month: number
  amount: string | number
  created_by: string
  created_at: string
  updated_at: string
}

type SavingsState = {
  spaceId: string | null
  monthValue: string
  saving: MonthlySaving | null
  isLoading: boolean
  error: string | null
}

function getPeriod(monthValue: string) {
  const [year, month] = monthValue.split('-').map(Number)
  return { year, month }
}

export function useMonthlySavings(spaceId: string | null, monthValue: string) {
  const [state, setState] = useState<SavingsState>({ spaceId: null, monthValue: '', saving: null, isLoading: true, error: null })
  const [requestVersion, setRequestVersion] = useState(0)
  const { year, month } = getPeriod(monthValue)

  useEffect(() => {
    let active = true
    const load = async () => {
      if (!spaceId) {
        if (active) setState({ spaceId: null, monthValue, saving: null, isLoading: false, error: null })
        return
      }
      if (!supabase) {
        if (active) setState({ spaceId, monthValue, saving: null, isLoading: false, error: 'No se pudo conectar con Supabase.' })
        return
      }

      if (active) setState({ spaceId, monthValue, saving: null, isLoading: true, error: null })
      const { data, error } = await supabase.from('monthly_savings').select('id, space_id, year, month, amount, created_by, created_at, updated_at').eq('space_id', spaceId).eq('year', year).eq('month', month).maybeSingle()
      if (!active) return
      if (error) {
        setState({ spaceId, monthValue, saving: null, isLoading: false, error: 'No pudimos cargar la reserva de ahorro.' })
        return
      }
      setState({ spaceId, monthValue, saving: data as MonthlySaving | null, isLoading: false, error: null })
    }
    void load()
    return () => { active = false }
  }, [month, monthValue, requestVersion, spaceId, year])

  const refresh = useCallback(() => setRequestVersion((version) => version + 1), [])

  const saveSaving = useCallback(async (amount: number) => {
    if (!supabase || !spaceId) return 'Selecciona un espacio antes de configurar la reserva.'
    if (!Number.isFinite(amount) || amount <= 0) return 'Ingresa una reserva mayor que cero.'

    if (state.saving) {
      const { data, error } = await supabase.from('monthly_savings').update({ amount }).eq('id', state.saving.id).select('id')
      if (error || !data?.length) return 'No pudimos actualizar la reserva. Es posible que ya no tengas permiso.'
    } else {
      const { error } = await supabase.from('monthly_savings').insert({ space_id: spaceId, year, month, amount })
      if (error?.code === '23505') {
        refresh()
        return 'La reserva ya fue creada por otro miembro. Inténtalo nuevamente para editarla.'
      }
      if (error) return 'No pudimos guardar la reserva. Inténtalo nuevamente.'
    }
    refresh()
    return null
  }, [month, refresh, spaceId, state.saving, year])

  const deleteSaving = useCallback(async () => {
    if (!supabase || !state.saving) return 'No hay reserva para eliminar.'
    const { data, error } = await supabase.from('monthly_savings').delete().eq('id', state.saving.id).select('id')
    if (error || !data?.length) return 'No pudimos eliminar la reserva. Es posible que ya no tengas permiso.'
    refresh()
    return null
  }, [refresh, state.saving])

  const isCurrentSelection = state.spaceId === spaceId && state.monthValue === monthValue
  return { ...state, saving: isCurrentSelection ? state.saving : null, isLoading: state.isLoading || !isCurrentSelection, refresh, saveSaving, deleteSaving }
}
