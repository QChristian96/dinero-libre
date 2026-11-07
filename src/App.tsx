import { useEffect, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import AuthScreen from './components/AuthScreen'
import SpacesPanel from './components/SpacesPanel'
import TransactionsList from './components/TransactionsList'
import BudgetPanel from './components/BudgetPanel'
import RecurringExpensesPanel from './components/RecurringExpensesPanel'
import MonthlySavingsPanel from './components/MonthlySavingsPanel'
import { supabase, isSupabaseConfigured } from './lib/supabase'
import { clearSpacesSelection, useSpaces } from './hooks/useSpaces'
import { useTransactions, type Category, type TransactionInput, type TransactionType } from './hooks/useTransactions'
import { calculateBudgetProgress, formatPen, getLocalMonthValue, summarizeMonth } from './lib/financialSummary'
import { useBudget } from './hooks/useBudget'
import { useRecurringExpenses } from './hooks/useRecurringExpenses'
import { useMonthlySavings } from './hooks/useMonthlySavings'
import { useFreeMoney } from './hooks/useFreeMoney'
import './App.css'

type Section = 'inicio' | 'movimientos' | 'planificacion' | 'configuracion'
type IconName = 'home' | 'movement' | 'chart' | 'settings' | 'plus' | 'arrow-up' | 'arrow-down' | 'food' | 'transport' | 'home-small' | 'more' | 'close' | 'calendar' | 'chevron'

function getLocalDateValue() {
  const date = new Date()
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function getFirstName(userMetadata: Record<string, unknown>) {
  const value = userMetadata.first_name ?? userMetadata.given_name ?? userMetadata.full_name ?? userMetadata.name
  return typeof value === 'string' && value.trim() ? value.trim().split(/\s+/)[0] : null
}

function formatCompactMonth(monthValue: string) {
  const [year, month] = monthValue.split('-').map(Number)
  const labels = ['Ene.', 'Feb.', 'Mar.', 'Abr.', 'May.', 'Jun.', 'Jul.', 'Ago.', 'Sep.', 'Oct.', 'Nov.', 'Dic.']
  return `${labels[month - 1] ?? ''} ${year}`
}

const navItems: { id: Section; label: string; icon: IconName }[] = [
  { id: 'inicio', label: 'Inicio', icon: 'home' },
  { id: 'movimientos', label: 'Movimientos', icon: 'movement' },
  { id: 'planificacion', label: 'Planificación', icon: 'chart' },
  { id: 'configuracion', label: 'Configuración', icon: 'settings' },
]

function Icon({ name, size = 22 }: { name: IconName; size?: number }) {
  const common = { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const }
  const paths: Record<IconName, React.ReactNode> = {
    home: <><path d="m3 10 9-7 9 7v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z" /><path d="M9 21v-7h6v7" /></>,
    movement: <><path d="M7 7h13l-3-3" /><path d="m20 7-3 3" /><path d="M17 17H4l3 3" /><path d="m4 17 3-3" /></>,
    chart: <><path d="M4 19V5" /><path d="M4 19h16" /><path d="m7 15 4-4 3 2 5-6" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.8 1.8 0 0 0 .36 2l.06.06-2.1 2.1-.06-.06a1.8 1.8 0 0 0-2-.36 1.8 1.8 0 0 0-1.1 1.65v.09h-3v-.09A1.8 1.8 0 0 0 10.45 18.7a1.8 1.8 0 0 0-2 .36l-.06.06-2.1-2.1.06-.06a1.8 1.8 0 0 0 .36-2 1.8 1.8 0 0 0-1.65-1.1h-.09v-3h.09A1.8 1.8 0 0 0 6.7 9.75a1.8 1.8 0 0 0-.36-2l-.06-.06 2.1-2.1.06.06a1.8 1.8 0 0 0 2 .36 1.8 1.8 0 0 0 1.1-1.65v-.09h3v.09a1.8 1.8 0 0 0 1.1 1.65 1.8 1.8 0 0 0 2-.36l.06-.06 2.1 2.1-.06.06a1.8 1.8 0 0 0-.36 2 1.8 1.8 0 0 0 1.65 1.1h.09v3h-.09A1.8 1.8 0 0 0 19.4 15Z" /></>,
    plus: <><path d="M12 5v14M5 12h14" /></>,
    'arrow-up': <><path d="M12 19V5" /><path d="m6 11 6-6 6 6" /></>,
    'arrow-down': <><path d="M12 5v14" /><path d="m18 13-6 6-6-6" /></>,
    food: <><path d="M7 3v8M4 3v5a3 3 0 0 0 6 0V3M7 11v10" /><path d="M17 3v18M17 3c3 2 3 7 0 9" /></>,
    transport: <><path d="M5 16 7 8h10l2 8" /><path d="M3 16h18v4H3z" /><circle cx="7" cy="20" r="1" /><circle cx="17" cy="20" r="1" /></>,
    'home-small': <><path d="m4 11 8-7 8 7v9H4Z" /><path d="M9 20v-5h6v5" /></>,
    more: <><circle cx="5" cy="12" r="1" fill="currentColor" /><circle cx="12" cy="12" r="1" fill="currentColor" /><circle cx="19" cy="12" r="1" fill="currentColor" /></>,
    close: <><path d="m6 6 12 12M18 6 6 18" /></>,
    calendar: <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 10h18" /></>,
    chevron: <path d="m8 10 4 4 4-4" />,
  }
  return <svg {...common} aria-hidden="true">{paths[name]}</svg>
}

function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [authLoading, setAuthLoading] = useState(isSupabaseConfigured)
  const [isOnline, setIsOnline] = useState(() => navigator.onLine)

  useEffect(() => {
    const goOnline = () => setIsOnline(true)
    const goOffline = () => setIsOnline(false)
    window.addEventListener('online', goOnline)
    window.addEventListener('offline', goOffline)
    return () => {
      window.removeEventListener('online', goOnline)
      window.removeEventListener('offline', goOffline)
    }
  }, [])

  useEffect(() => {
    if (!supabase) return

    let active = true
    void supabase.auth.getSession().then(({ data }) => {
      if (active) {
        setSession(data.session)
        setAuthLoading(false)
      }
    })

    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      if (active) {
        setSession(nextSession)
        setAuthLoading(false)
      }
    })

    return () => {
      active = false
      listener.subscription.unsubscribe()
    }
  }, [])

  if (authLoading && isSupabaseConfigured) return <main className="auth-page"><p className="auth-loading">Cargando Dinero Libre…</p></main>
  if (!isOnline) return <main className="auth-page"><section className="offline-card"><span aria-hidden="true">⌁</span><h1>Sin conexión</h1><p>Conéctate a internet para consultar datos financieros actualizados.</p></section></main>
  if (!session) return <AuthScreen />
  return <Dashboard key={session.user.id} userId={session.user.id} userEmail={session.user.email ?? 'Usuario'} userFirstName={getFirstName(session.user.user_metadata)} />
}

function Dashboard({ userId, userEmail, userFirstName }: { userId: string; userEmail: string; userFirstName: string | null }) {
  const [section, setSection] = useState<Section>('inicio')
  const [formOpen, setFormOpen] = useState(false)
  const [transactionNotice, setTransactionNotice] = useState<string | null>(null)
  const [selectedMonth, setSelectedMonth] = useState(getLocalMonthValue)
  const spaces = useSpaces(userId)
  const transactions = useTransactions(spaces.selectedSpace?.id ?? null, selectedMonth)
  const budget = useBudget(spaces.selectedSpace?.id ?? null, selectedMonth)
  const recurringExpenses = useRecurringExpenses(spaces.selectedSpace?.id ?? null, selectedMonth)
  const monthlySavings = useMonthlySavings(spaces.selectedSpace?.id ?? null, selectedMonth)
  const monthlySummary = summarizeMonth(transactions.transactions, selectedMonth)
  const freeMoney = useFreeMoney(
    monthlySummary,
    recurringExpenses.expenses,
    recurringExpenses.payments,
    monthlySavings.saving?.amount ?? null,
    selectedMonth,
    [transactions, recurringExpenses, monthlySavings],
  )

  const closeForm = () => setFormOpen(false)
  const openForm = () => {
    if (!spaces.selectedSpace) {
      setTransactionNotice('Selecciona un espacio antes de registrar un movimiento.')
      return
    }
    setFormOpen(true)
  }
  const saveTransaction = async (input: TransactionInput) => {
    const error = await transactions.createTransaction(input)
    if (error) return error
    budget.refresh()
    setTransactionNotice('Movimiento guardado correctamente.')
    return null
  }
  const updateTransaction = async (id: string, values: Parameters<typeof transactions.updateTransaction>[1]) => {
    const error = await transactions.updateTransaction(id, values)
    if (!error) budget.refresh()
    return error
  }
  const deleteTransaction = async (id: string) => {
    const error = await transactions.deleteTransaction(id)
    if (!error) budget.refresh()
    return error
  }
  const signOut = async () => {
    clearSpacesSelection(userId)
    if (supabase) await supabase.auth.signOut()
  }
  const refreshAfterRecurringPayments = async () => {
    const [transactionsSynced, recurringSynced] = await Promise.all([transactions.reload(), recurringExpenses.reload()])
    return transactionsSynced && recurringSynced
  }
  const navigate = (nextSection: Section) => {
    setSection(nextSection)
    if (nextSection === 'inicio') {
      transactions.refresh()
      recurringExpenses.refresh()
      monthlySavings.refresh()
    }
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><span className="brand-mark">D</span><span>dinero<span>libre</span></span></div>
        <nav className="side-nav" aria-label="Principal">{navItems.map((item) => <NavButton key={item.id} item={item} active={section === item.id} onClick={() => navigate(item.id)} />)}</nav>
        <div className="profile"><span className="avatar">{userEmail.slice(0, 2).toUpperCase()}</span><div><strong>{userEmail}</strong><small>{spaces.selectedSpace?.name ?? 'Sin espacio seleccionado'}</small></div><button className="sign-out" onClick={signOut}>Salir</button></div>
      </aside>

      <main className="main-content">
        {section === 'inicio' ? <Home userFirstName={userFirstName} spaces={spaces} transactions={transactions} budget={budget} summary={monthlySummary} freeMoney={freeMoney} userId={userId} month={selectedMonth} onMonthChange={setSelectedMonth} notice={transactionNotice} onUpdate={updateTransaction} onDelete={deleteTransaction} onOpenForm={openForm} onRetryFinancialData={() => { transactions.refresh(); recurringExpenses.refresh(); monthlySavings.refresh() }} /> : section === 'movimientos' ? <MovementsSection transactions={transactions} userId={userId} notice={transactionNotice} onUpdate={updateTransaction} onDelete={deleteTransaction} onOpenForm={openForm} /> : section === 'planificacion' ? <PlanningSection transactions={transactions} budget={budget} recurringExpenses={recurringExpenses} monthlySavings={monthlySavings} month={selectedMonth} onMonthChange={setSelectedMonth} onPaymentsRecorded={refreshAfterRecurringPayments} /> : section === 'configuracion' ? <SpacesPanel userId={userId} spaces={spaces.spaces} selectedSpace={spaces.selectedSpace} isLoading={spaces.isLoading} error={spaces.error} onRetry={spaces.retry} onSelectSpace={spaces.selectSpace} onSignOut={signOut} /> : <EmptySection section={section} onOpenForm={openForm} onSignOut={signOut} />}
      </main>

      <button className="floating-add" onClick={openForm} aria-label="Registrar movimiento"><Icon name="plus" size={25} /></button>
      <nav className="bottom-nav" aria-label="Navegación móvil">{navItems.map((item) => <NavButton key={item.id} item={item} active={section === item.id} onClick={() => navigate(item.id)} />)}</nav>
      {formOpen && spaces.selectedSpace && <MovementForm spaceName={spaces.selectedSpace.name} categories={transactions.categories} onClose={closeForm} onSubmit={saveTransaction} />}
    </div>
  )
}

function NavButton({ item, active, onClick }: { item: { id: Section; label: string; icon: IconName }; active: boolean; onClick: () => void }) {
  return <button className={`nav-button ${active ? 'active' : ''}`} onClick={onClick}><Icon name={item.icon} /><span>{item.label}</span></button>
}

function Home({ userFirstName, spaces, transactions, budget, summary, freeMoney, userId, month, onMonthChange, notice, onUpdate, onDelete, onOpenForm, onRetryFinancialData }: { userFirstName: string | null; spaces: ReturnType<typeof useSpaces>; transactions: ReturnType<typeof useTransactions>; budget: ReturnType<typeof useBudget>; summary: ReturnType<typeof summarizeMonth>; freeMoney: ReturnType<typeof useFreeMoney>; userId: string; month: string; onMonthChange: (month: string) => void; notice: string | null; onUpdate: ReturnType<typeof useTransactions>['updateTransaction']; onDelete: ReturnType<typeof useTransactions>['deleteTransaction']; onOpenForm: () => void; onRetryFinancialData: () => void }) {
  const budgetProgress = budget.budget ? calculateBudgetProgress(budget.budget.amount, summary.expenseCents) : null
  return <>
    <header className="page-header"><div><p className="eyebrow">RESUMEN FINANCIERO</p><h1>{userFirstName ? `Hola, ${userFirstName}` : '¡Hola'} <span>👋</span></h1></div><div className="header-selectors"><MonthSelector month={month} onChange={onMonthChange} /><SpaceSelector spaces={spaces} /></div></header>
    <MonthlySummary summary={summary} freeMoney={freeMoney} onRetry={onRetryFinancialData} />
    <section className="section-block budget-section"><div className="section-heading"><div><p className="eyebrow">PRESUPUESTO GLOBAL</p><h2>Presupuesto</h2></div></div><BudgetPanel budgetAmount={budget.budget?.amount ?? null} progress={budgetProgress} isLoading={budget.isLoading || transactions.isLoading} error={budget.error} onRetry={budget.refresh} onSave={budget.saveBudget} onDelete={budget.deleteBudget} /></section>
    <section className="section-block"><div className="section-heading"><div><p className="eyebrow">DATOS REALES DEL ESPACIO</p><h2>Movimientos recientes</h2></div></div><TransactionContent transactions={transactions} userId={userId} limit={4} editable={false} onUpdate={onUpdate} onDelete={onDelete} />{notice && <p className="transaction-state success" role="status">{notice}</p>}</section>
    <button className="new-movement" onClick={onOpenForm}><Icon name="plus" size={19} /> Registrar movimiento</button>
  </>
}

function PlanningSection({ transactions, budget, recurringExpenses, monthlySavings, month, onMonthChange, onPaymentsRecorded }: { transactions: ReturnType<typeof useTransactions>; budget: ReturnType<typeof useBudget>; recurringExpenses: ReturnType<typeof useRecurringExpenses>; monthlySavings: ReturnType<typeof useMonthlySavings>; month: string; onMonthChange: (month: string) => void; onPaymentsRecorded: () => Promise<boolean> }) {
  const summary = summarizeMonth(transactions.transactions, month)
  const budgetProgress = budget.budget ? calculateBudgetProgress(budget.budget.amount, summary.expenseCents) : null
  return <section className="movements-page"><div className="section-heading"><div><p className="eyebrow">PLANIFICACIÓN</p><h1>Presupuesto mensual</h1></div><MonthSelector month={month} onChange={onMonthChange} /></div><p className="planning-intro">Configura un límite global para el espacio y período seleccionados.</p><BudgetPanel budgetAmount={budget.budget?.amount ?? null} progress={budgetProgress} isLoading={budget.isLoading || transactions.isLoading} error={budget.error} onRetry={budget.refresh} onSave={budget.saveBudget} onDelete={budget.deleteBudget} /><RecurringExpensesPanel key={month} expenses={recurringExpenses.expenses} payments={recurringExpenses.payments} transactions={transactions.transactions} categories={transactions.categories} month={month} isLoading={recurringExpenses.isLoading || transactions.isLoading} error={recurringExpenses.error} isRecordingPayments={recurringExpenses.isRecordingPayments} onRetry={recurringExpenses.refresh} onCreate={recurringExpenses.createExpense} onUpdate={recurringExpenses.updateExpense} onLink={recurringExpenses.linkPayment} onUnlink={recurringExpenses.unlinkPayment} onRecordPayments={recurringExpenses.recordPayments} onPaymentsRecorded={onPaymentsRecorded} /><MonthlySavingsPanel amount={monthlySavings.saving?.amount ?? null} isLoading={monthlySavings.isLoading} error={monthlySavings.error} onRetry={monthlySavings.refresh} onSave={monthlySavings.saveSaving} onDelete={monthlySavings.deleteSaving} /></section>
}

function MonthSelector({ month, onChange }: { month: string; onChange: (month: string) => void }) {
  return <label className="month-select"><span className="sr-only">Mes del resumen</span><span className="month-select-compact" aria-hidden="true">{formatCompactMonth(month)}</span><input type="month" value={month} onChange={(event) => onChange(event.target.value)} /></label>
}

function MonthlySummary({ summary, freeMoney, onRetry }: { summary: ReturnType<typeof summarizeMonth>; freeMoney: ReturnType<typeof useFreeMoney>; onRetry: () => void }) {
  if (freeMoney.status === 'loading') return <section className="balance-card summary-state">Cargando disponibilidad mensual…</section>
  if (freeMoney.status === 'error') return <section className="balance-card summary-state">No pudimos calcular tu disponibilidad mensual. <button onClick={onRetry}>Reintentar</button></section>
  const result = freeMoney.result
  if (!result) return <section className="balance-card summary-state">No hay datos suficientes para calcular tu disponibilidad mensual.</section>
  return <section className="balance-card free-money-card"><div className="balance-top"><span>DINERO LIBRE</span></div><strong>{formatPen(result.freeMoneyCents)}</strong><p>{freeMoney.status === 'empty' ? 'Sin obligaciones ni reservas configuradas este mes.' : 'Disponibilidad mensual estimada; no es saldo bancario.'}</p><div className="free-money-breakdown"><span>Balance mensual <b>{formatPen(summary.balanceCents)}</b></span><span>Obligaciones pendientes <b>- {formatPen(result.pendingRecurringCents)}</b></span><span>Ahorro reservado <b>- {formatPen(result.savingsReservedCents)}</b></span></div><div className="balance-stats"><div><span className="stat-icon income"><Icon name="arrow-up" size={17} /></span><p>Ingresos <b>{formatPen(summary.incomeCents)}</b></p></div><div><span className="stat-icon expense"><Icon name="arrow-down" size={17} /></span><p>Gastos <b>{formatPen(summary.expenseCents)}</b></p></div></div></section>
}

function MovementsSection({ transactions, userId, notice, onUpdate, onDelete, onOpenForm }: { transactions: ReturnType<typeof useTransactions>; userId: string; notice: string | null; onUpdate: ReturnType<typeof useTransactions>['updateTransaction']; onDelete: ReturnType<typeof useTransactions>['deleteTransaction']; onOpenForm: () => void }) {
  return <section className="movements-page"><div className="section-heading"><div><p className="eyebrow">DATOS REALES DEL ESPACIO</p><h1>Movimientos</h1></div><button className="new-movement compact" onClick={onOpenForm}><Icon name="plus" size={17} /> Registrar</button></div>{notice && <p className="transaction-state success" role="status">{notice}</p>}<TransactionContent transactions={transactions} userId={userId} editable onUpdate={onUpdate} onDelete={onDelete} /></section>
}

function TransactionContent({ transactions, userId, limit, editable, onUpdate, onDelete }: { transactions: ReturnType<typeof useTransactions>; userId: string; limit?: number; editable: boolean; onUpdate: ReturnType<typeof useTransactions>['updateTransaction']; onDelete: ReturnType<typeof useTransactions>['deleteTransaction'] }) {
  if (transactions.isLoading) return <p className="transaction-state">Cargando movimientos…</p>
  if (transactions.error) return <p className="transaction-state error">{transactions.error} <button onClick={transactions.refresh}>Reintentar</button></p>
  return <TransactionsList transactions={limit ? transactions.transactions.slice(0, limit) : transactions.transactions} categories={transactions.categories} currentUserId={userId} editable={editable} onUpdate={onUpdate} onDelete={onDelete} />
}

function SpaceSelector({ spaces }: { spaces: ReturnType<typeof useSpaces> }) {
  if (spaces.isLoading) return <span className="space-status">Cargando espacio…</span>
  if (spaces.error) return <span className="space-status error">{spaces.error}<button onClick={spaces.retry}>Reintentar</button></span>
  if (spaces.spaces.length === 0) return <span className="space-status">Aún no tienes espacios.</span>

  return <label className="space-select"><span className="sr-only">Espacio financiero</span><select value={spaces.selectedSpaceId ?? ''} onChange={(event) => spaces.selectSpace(event.target.value)}>{spaces.spaces.map((space) => <option value={space.id} key={space.id}>{space.name}{space.kind === 'personal' ? ' · Personal' : ' · Compartido'}</option>)}</select><Icon name="chevron" size={17} /></label>
}

function EmptySection({ section, onOpenForm, onSignOut }: { section: Section; onOpenForm: () => void; onSignOut: () => void }) {
  const content: [string, string] = section === 'movimientos'
    ? ['Movimientos', 'Aquí podrás revisar todos tus ingresos y gastos.']
    : section === 'planificacion'
      ? ['Planificación', 'Estamos preparando tus herramientas de planificación.']
      : ['Configuración', 'Personaliza tu experiencia y tus espacios.']
  return <section className="empty-page"><p className="eyebrow">PRÓXIMAMENTE</p><h1>{content[0]}</h1><div className="empty-illustration"><Icon name={section === 'movimientos' ? 'movement' : section === 'planificacion' ? 'chart' : 'settings'} size={34} /></div><h2>Aún no hay nada por aquí</h2><p>{content[1]}</p>{section === 'movimientos' && <button className="new-movement" onClick={onOpenForm}><Icon name="plus" size={19} /> Registrar movimiento</button>}{section === 'configuracion' && <button className="new-movement" onClick={onSignOut}>Cerrar sesión</button>}</section>
}

function MovementForm({ spaceName, categories, onClose, onSubmit }: { spaceName: string; categories: Category[]; onClose: () => void; onSubmit: (input: TransactionInput) => Promise<string | null> }) {
  const [transactionType, setTransactionType] = useState<TransactionType>('expense')
  const [categoryId, setCategoryId] = useState('')
  const [amount, setAmount] = useState('')
  const [date, setDate] = useState(getLocalDateValue)
  const [description, setDescription] = useState('')
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID())
  const [isSaving, setIsSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const availableCategories = categories.filter((category) => category.transaction_type === transactionType)

  const selectType = (type: TransactionType) => {
    setTransactionType(type)
    setCategoryId('')
  }

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const numericAmount = Number(amount.replace(',', '.'))
    if (isSaving || !categoryId || !Number.isFinite(numericAmount) || numericAmount <= 0) {
      setError('Ingresa un monto positivo y una categor�a.')
      return
    }

    setIsSaving(true)
    setError(null)
    const result = await onSubmit({
      transaction_type: transactionType,
      amount: numericAmount,
      category_id: categoryId,
      description: description.trim() || null,
      occurred_on: date,
      idempotency_key: idempotencyKey,
    })
    setIsSaving(false)
    if (result) {
      setError(result)
      return
    }
    setIdempotencyKey(crypto.randomUUID())
    onClose()
  }

  return <div className="modal-backdrop" role="presentation" onMouseDown={onClose}><section className="movement-modal" role="dialog" aria-modal="true" aria-labelledby="form-title" onMouseDown={(event) => event.stopPropagation()}><header><div><p className="eyebrow">NUEVO MOVIMIENTO</p><h2 id="form-title">Registrar movimiento</h2></div><button className="close-button" onClick={onClose} aria-label="Cerrar formulario" disabled={isSaving}><Icon name="close" /></button></header><form onSubmit={submit}><div className="type-toggle"><button type="button" className={transactionType === 'expense' ? 'selected' : ''} onClick={() => selectType('expense')} disabled={isSaving}>Gasto</button><button type="button" className={transactionType === 'income' ? 'selected' : ''} onClick={() => selectType('income')} disabled={isSaving}>Ingreso</button></div><label className="amount-field">Monto <div><span>S/</span><input value={amount} onChange={(event) => setAmount(event.target.value)} inputMode="decimal" placeholder="0.00" autoFocus disabled={isSaving} /></div></label><div className="form-grid"><label>Categor�a <span className="select-wrap"><select value={categoryId} onChange={(event) => setCategoryId(event.target.value)} disabled={isSaving} required><option value="" disabled>{categories.length === 0 ? 'Cargando categor�as�' : 'Selecciona una categor�a'}</option>{availableCategories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select><Icon name="chevron" size={17} /></span></label><label>Fecha <span className="input-with-icon"><input type="date" value={date} onChange={(event) => setDate(event.target.value)} disabled={isSaving} /><Icon name="calendar" size={17} /></span></label></div><label>Descripci�n <input type="text" value={description} onChange={(event) => setDescription(event.target.value)} maxLength={500} placeholder={transactionType === 'expense' ? '�En qu� fue este gasto?' : '�De d�nde proviene este ingreso?'} disabled={isSaving} /></label><div className="selected-space"><span>Espacio</span><strong>{spaceName}</strong></div>{error && <p className="form-error" role="alert">{error}</p>}<div className="form-actions"><button type="button" className="cancel-button" onClick={onClose} disabled={isSaving}>Cancelar</button><button type="submit" className="save-button" disabled={isSaving || categories.length === 0}>{isSaving ? 'Guardando�' : 'Guardar movimiento'}</button></div></form></section></div>
}

export default App
