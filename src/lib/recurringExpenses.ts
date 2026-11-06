export type RecurringStatus = 'pendiente' | 'vencido' | 'pagado' | 'inactivo'

export function getPeruToday() {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Lima',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date())
  const value = (type: string) => parts.find((part) => part.type === type)?.value ?? ''
  return `${value('year')}-${value('month')}-${value('day')}`
}

export function getRecurringDueDate(year: number, month: number, dueDay: number) {
  const lastDay = new Date(year, month, 0).getDate()
  return `${year}-${String(month).padStart(2, '0')}-${String(Math.min(dueDay, lastDay)).padStart(2, '0')}`
}

export function getRecurringStatus(isActive: boolean, hasPayment: boolean, dueDate: string, peruToday = getPeruToday()): RecurringStatus {
  if (!isActive) return 'inactivo'
  if (hasPayment) return 'pagado'
  return dueDate < peruToday ? 'vencido' : 'pendiente'
}
