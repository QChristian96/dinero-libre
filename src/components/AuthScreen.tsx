import { useState, type FormEvent } from 'react'
import { supabase, isSupabaseConfigured } from '../lib/supabase'

type AuthMode = 'signin' | 'signup'

function AuthScreen() {
  const [mode, setMode] = useState<AuthMode>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [confirmationSent, setConfirmationSent] = useState(false)

  const changeMode = (nextMode: AuthMode) => {
    setMode(nextMode)
    setError('')
    setConfirmationSent(false)
  }

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!supabase || loading) return

    setLoading(true)
    setError('')

    if (mode === 'signup') {
      const { data, error: signUpError } = await supabase.auth.signUp({
        email,
        password,
        options: { emailRedirectTo: window.location.origin },
      })

      if (signUpError) setError(signUpError.message)
      else if (!data.session) setConfirmationSent(true)
    } else {
      const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
      if (signInError) setError('No pudimos iniciar sesión. Revisa tu correo y contraseña.')
    }

    setLoading(false)
  }

  return <main className="auth-page">
    <section className="auth-card" aria-labelledby="auth-title">
      <div className="brand auth-brand"><span className="brand-mark">D</span><span>dinero<span>libre</span></span></div>
      <p className="eyebrow">TU DINERO, CON CLARIDAD</p>
      <h1 id="auth-title">{mode === 'signin' ? 'Bienvenido de vuelta' : 'Empieza con Dinero Libre'}</h1>
      <p className="auth-intro">{mode === 'signin' ? 'Ingresa para ver tu resumen financiero.' : 'Crea tu cuenta para tomar decisiones con tranquilidad.'}</p>

      {!isSupabaseConfigured ? <p className="auth-message error">Falta configurar el acceso a Supabase. Revisa las variables de entorno de la aplicación.</p>
        : confirmationSent ? <div className="auth-message success"><strong>Revisa tu correo</strong><span>Te enviamos un enlace de confirmación a {email}. Confirma tu cuenta para ingresar.</span><button type="button" className="auth-link" onClick={() => changeMode('signin')}>Volver a iniciar sesión</button></div>
          : <form className="auth-form" onSubmit={handleSubmit}>
            <label>Correo electrónico<input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="tu@correo.com" autoComplete="email" required disabled={loading} /></label>
            <label>Contraseña<input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Mínimo 6 caracteres" autoComplete={mode === 'signin' ? 'current-password' : 'new-password'} minLength={6} required disabled={loading} /></label>
            {error && <p className="auth-message error" role="alert">{error}</p>}
            <button className="auth-submit" type="submit" disabled={loading}>{loading ? 'Procesando…' : mode === 'signin' ? 'Iniciar sesión' : 'Crear cuenta'}</button>
          </form>}

      {!confirmationSent && <p className="auth-switch">{mode === 'signin' ? '¿Aún no tienes cuenta?' : '¿Ya tienes una cuenta?'} <button type="button" onClick={() => changeMode(mode === 'signin' ? 'signup' : 'signin')} disabled={loading}>{mode === 'signin' ? 'Regístrate' : 'Inicia sesión'}</button></p>}
    </section>
  </main>
}

export default AuthScreen
