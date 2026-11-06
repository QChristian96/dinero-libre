import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export type FinancialSpace = {
  id: string
  name: string
  kind: 'personal' | 'shared'
  owner_id: string
}

type SpacesState = {
  spaces: FinancialSpace[]
  selectedSpaceId: string | null
  isLoading: boolean
  error: string | null
}

const selectionKey = (userId: string) => `dinero-libre:selected-space:${userId}`

export function clearSpacesSelection(userId: string) {
  sessionStorage.removeItem(selectionKey(userId))
}

export function useSpaces(userId: string) {
  const [state, setState] = useState<SpacesState>({
    spaces: [],
    selectedSpaceId: null,
    isLoading: true,
    error: null,
  })
  const [requestVersion, setRequestVersion] = useState(0)

  useEffect(() => {
    let isCurrentUser = true

    const loadSpaces = async () => {
      if (!supabase) {
        if (isCurrentUser) setState((current) => ({ ...current, isLoading: false, error: 'No se pudo conectar con Supabase.' }))
        return
      }

      if (isCurrentUser) setState((current) => ({ ...current, isLoading: true, error: null }))
      const { data, error } = await supabase
        .from('spaces')
        .select('id, name, kind, owner_id')
        .order('created_at', { ascending: true })

      if (!isCurrentUser) return

      if (error) {
        setState((current) => ({ ...current, isLoading: false, error: 'No pudimos cargar tus espacios. Inténtalo nuevamente.' }))
        return
      }

      const spaces = (data ?? []) as FinancialSpace[]
      const savedSpaceId = sessionStorage.getItem(selectionKey(userId))
      const savedSpaceIsAuthorized = spaces.some((space) => space.id === savedSpaceId)
      const personalSpace = spaces.find((space) => space.kind === 'personal' && space.owner_id === userId)
      const nextSelectedSpaceId = savedSpaceIsAuthorized
        ? savedSpaceId
        : personalSpace?.id ?? spaces[0]?.id ?? null

      if (nextSelectedSpaceId) sessionStorage.setItem(selectionKey(userId), nextSelectedSpaceId)
      else clearSpacesSelection(userId)

      setState({ spaces, selectedSpaceId: nextSelectedSpaceId, isLoading: false, error: null })
    }

    void loadSpaces()
    return () => { isCurrentUser = false }
  }, [requestVersion, userId])

  const selectSpace = useCallback((spaceId: string) => {
    setState((current) => {
      if (!current.spaces.some((space) => space.id === spaceId)) return current
      sessionStorage.setItem(selectionKey(userId), spaceId)
      return { ...current, selectedSpaceId: spaceId }
    })
  }, [userId])

  const retry = useCallback(() => setRequestVersion((version) => version + 1), [])
  const selectedSpace = state.spaces.find((space) => space.id === state.selectedSpaceId) ?? null

  return { ...state, selectedSpace, selectSpace, retry }
}
