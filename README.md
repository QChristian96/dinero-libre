# Dinero Libre

Dinero Libre es una PWA para administrar finanzas personales y compartidas: registra ingresos y gastos, organiza presupuestos, obligaciones recurrentes y reservas de ahorro, y muestra la disponibilidad mensual estimada de cada espacio.

**Probar la aplicación:** [https://dinero-libre.pages.dev](https://dinero-libre.pages.dev)

## Problema que resuelve

Llevar el control del dinero suele implicar separar gastos personales, gastos compartidos, pagos recurrentes, presupuestos y ahorro en varias herramientas. Dinero Libre reúne esos elementos en un mismo espacio para personas que quieren tener una lectura mensual más clara de sus ingresos, gastos y compromisos.

Está pensado como un proyecto de portafolio para personas que gestionan sus finanzas personales y para pequeños grupos que comparten un espacio financiero, como parejas o familias.

## Funciones implementadas

- Registro, inicio y cierre de sesión con correo y contraseña.
- Confirmación de correo y recuperación de sesión existente.
- Espacio personal automático por usuario.
- Espacios compartidos mediante códigos de invitación de un solo uso.
- Registro de ingresos y gastos reales en PEN.
- Categorías de ingresos y gastos.
- Historial de movimientos por espacio, con edición y eliminación limitada al autor.
- Presupuesto mensual global por espacio.
- Gastos fijos mensuales, estado pendiente/vencido/pagado y vínculo con gastos reales.
- Reserva mensual de ahorro.
- Indicador **Dinero Libre** como disponibilidad mensual estimada.
- Resumen mensual de ingresos, gastos y balance.
- PWA instalable en navegadores compatibles, Android y iPhone/iPad.

> Dinero Libre es una estimación mensual basada en los datos registrados; no representa un saldo bancario conectado.

## Stack

- React 19
- TypeScript
- Vite
- Tailwind CSS
- Supabase Auth
- Supabase PostgreSQL con Row Level Security (RLS)
- `vite-plugin-pwa` para manifest, iconos y service worker

## Arquitectura

```text
src/
├── components/   # Paneles y formularios de interfaz
├── hooks/        # Consultas y mutaciones a Supabase
├── lib/          # Cálculos financieros y cliente Supabase
└── App.tsx       # Composición de navegación y vistas

supabase/
├── migrations/   # Esquema, RLS, triggers y funciones SQL
└── tests/        # Pruebas SQL de seguridad transaccionales
```

Las migraciones separan perfiles, espacios, movimientos, presupuestos, obligaciones recurrentes y reservas de ahorro. Los cálculos monetarios del frontend trabajan con céntimos usando `bigint` para evitar errores de coma flotante.

## Seguridad

- Supabase Auth controla la identidad de cada usuario.
- PostgreSQL RLS aísla perfiles, espacios, movimientos, presupuestos, obligaciones y reservas por membresía de espacio.
- Los espacios compartidos permiten lectura a miembros autorizados; los movimientos solo pueden ser modificados o eliminados por su autor.
- Las invitaciones se almacenan como hash, caducan y son de un solo uso.
- El frontend utiliza únicamente la URL del proyecto y la Publishable Key de Supabase. No debe incluir claves `service_role` ni claves secretas.

## Ejecución local

### Requisitos

- Node.js 20 o superior.
- Un proyecto Supabase con las migraciones de `supabase/migrations` aplicadas.

### Instalación

```bash
npm install
```

Crea un archivo `.env.local` en la raíz del proyecto:

```env
VITE_SUPABASE_URL=https://tu-proyecto.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=tu_publishable_key
```

No publiques ese archivo ni reemplaces la Publishable Key por una clave administrativa.

### Desarrollo

```bash
npm run dev
```

### Validación y build

```bash
npm run lint
npm run build
npm run preview
```

## PWA

La aplicación incluye manifest, iconos de instalación y service worker para el shell estático de la interfaz. Puede instalarse en Android, iPhone/iPad y navegadores compatibles.

Los datos financieros requieren conexión a internet: el service worker no almacena respuestas de Supabase, Auth ni datos dinámicos. Sin conexión, la aplicación muestra un aviso en lugar de presentar importes financieros posiblemente desactualizados.

## Capturas

> Pendiente: agregar capturas reales de Inicio, Movimientos, Planificación y Configuración.

## Desarrollo

Proyecto personal desarrollado para portafolio. El objetivo es demostrar una implementación de frontend financiero con autenticación, aislamiento de datos por RLS y una interfaz responsive orientada a móvil.
