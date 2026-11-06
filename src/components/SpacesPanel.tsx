import { useState, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import type { FinancialSpace } from '../hooks/useSpaces'

type BusyAction = 'create' | 'invite' | 'join' | null

type SpacesPanelProps = {
  userId: string
  spaces: FinancialSpace[]
  selectedSpace: FinancialSpace | null
  isLoading: boolean
  error: string | null
  onRetry: () => void
  onSelectSpace: (spaceId: string) => void
  onSignOut: () => void
}

function SpacesPanel({ userId, spaces, selectedSpace, isLoading, error, onRetry, onSelectSpace, onSignOut }: SpacesPanelProps) {
  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [invitationCode, setInvitationCode] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busyAction, setBusyAction] = useState<BusyAction>(null)
  const [copied, setCopied] = useState(false)

  const selectSpace = (spaceId: string) => {
    setInvitationCode(null)
    setCopied(false)
    onSelectSpace(spaceId)
  }

  const createSpace = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!supabase || busyAction || !name.trim()) return

    setBusyAction('create')
    setActionError(null)
    setMessage(null)
    const { error: rpcError } = await supabase.rpc('create_shared_space', { space_name: name.trim() })
    setBusyAction(null)

    if (rpcError) {
      setActionError('No pudimos crear el espacio compartido. Inténtalo nuevamente.')
      return
    }

    setName('')
    setMessage('Espacio compartido creado. Ya puedes seleccionarlo para generar un código.')
    onRetry()
  }

  const generateInvitation = async () => {
    if (!supabase || busyAction || !selectedSpace) return

    setBusyAction('invite')
    setActionError(null)
    setMessage(null)
    const { data, error: rpcError } = await supabase.rpc('create_space_invitation', { target_space_id: selectedSpace.id })
    setBusyAction(null)

    if (rpcError || !data) {
      setActionError('No pudimos generar el código. Verifica que seas propietario del espacio e inténtalo nuevamente.')
      return
    }

    setInvitationCode(data)
    setMessage('Código generado. Compártelo solo con la persona que deseas invitar.')
  }

  const joinSpace = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!supabase || busyAction || code.trim().length !== 8) return

    setBusyAction('join')
    setActionError(null)
    setMessage(null)
    const { data, error: rpcError } = await supabase.rpc('join_shared_space', { invitation_code: code.trim().toUpperCase() })
    setBusyAction(null)

    if (rpcError) {
      setActionError('No pudimos procesar el código. Inténtalo nuevamente más tarde.')
      return
    }

    if (!data) {
      setActionError('El código no es válido, venció, ya fue usado o debes esperar antes de intentarlo otra vez.')
      return
    }

    setCode('')
    setMessage('Te uniste al espacio compartido. Ya está disponible en tu selector de espacios.')
    onRetry()
  }

  const copyInvitation = async () => {
    if (!invitationCode || !navigator.clipboard) return
    try {
      await navigator.clipboard.writeText(invitationCode)
      setCopied(true)
    } catch {
      setActionError('No pudimos copiar el código. Selecciónalo y cópialo manualmente.')
    }
  }

  const selectedIsOwnedShared = selectedSpace?.kind === 'shared' && selectedSpace.owner_id === userId

  return <section className="spaces-panel" aria-labelledby="spaces-title">
    <header className="spaces-header"><div><p className="eyebrow">ESPACIOS FINANCIEROS</p><h1 id="spaces-title">Tus espacios</h1><p>Tu espacio personal y los espacios compartidos a los que perteneces.</p></div></header>

    {isLoading && <p className="spaces-state">Cargando tus espacios…</p>}
    {error && <div className="spaces-state error"><span>{error}</span><button onClick={onRetry}>Reintentar</button></div>}
    {!isLoading && !error && spaces.length === 0 && <p className="spaces-state">Aún no tienes espacios disponibles.</p>}

    {!isLoading && !error && spaces.length > 0 && <label className="spaces-current">Espacio activo<select value={selectedSpace?.id ?? ''} onChange={(event) => selectSpace(event.target.value)}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}{space.kind === 'personal' ? ' · Personal' : ' · Compartido'}</option>)}</select></label>}

    <div className="spaces-grid">
      <article className="spaces-card"><h2>Crear espacio compartido</h2><p>Crea un espacio para organizarte con tu pareja, familia o equipo.</p><form onSubmit={createSpace}><label>Nombre del espacio<input value={name} onChange={(event) => setName(event.target.value)} maxLength={80} placeholder="Ej. Hogar" disabled={busyAction !== null} required /></label><button className="spaces-primary" type="submit" disabled={busyAction !== null || !name.trim()}>{busyAction === 'create' ? 'Creando…' : 'Crear espacio'}</button></form></article>

      <article className="spaces-card"><h2>Unirme con un código</h2><p>Ingresa el código de 8 caracteres que te compartieron.</p><form onSubmit={joinSpace}><label>Código de invitación<input className="invite-input" value={code} onChange={(event) => setCode(event.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8))} placeholder="ABCDEFGH" maxLength={8} autoCapitalize="characters" disabled={busyAction !== null} required /></label><button className="spaces-primary" type="submit" disabled={busyAction !== null || code.length !== 8}>{busyAction === 'join' ? 'Uniéndote…' : 'Unirme al espacio'}</button></form></article>
    </div>

    <article className="spaces-card invitation-card"><h2>Invitar a un espacio</h2>{selectedIsOwnedShared ? <><p>Genera un código para <strong>{selectedSpace.name}</strong>. Vence en 24 horas y se usa una sola vez.</p><button className="spaces-primary" type="button" onClick={generateInvitation} disabled={busyAction !== null}>{busyAction === 'invite' ? 'Generando…' : 'Generar código'}</button>{invitationCode && <div className="generated-code"><strong>{invitationCode}</strong><button type="button" onClick={copyInvitation}>{copied ? 'Copiado' : 'Copiar código'}</button><small>Cópialo y compártelo manualmente por WhatsApp.</small></div>}</> : <p>{selectedSpace?.kind === 'shared' ? 'Solo la persona propietaria puede generar códigos para este espacio.' : 'Selecciona un espacio compartido que te pertenezca para generar un código.'}</p>}</article>

    {actionError && <p className="spaces-feedback error" role="alert">{actionError}</p>}
    {message && <p className="spaces-feedback success" role="status">{message}</p>}
    <button className="spaces-sign-out" onClick={onSignOut}>Cerrar sesión</button>
  </section>
}

export default SpacesPanel
