import * as Sentry from '@sentry/browser'

Sentry.init({
  dsn: 'https://8839eedcd5ef62fb1e42ce3916830228@o4511298448261120.ingest.de.sentry.io/4511298451865680',
  environment: import.meta.env.MODE,
  enabled: import.meta.env.PROD,
})

export function setSentryUser(user) {
  Sentry.setUser({ id: user.id })
}

export function captureError(err, context) {
  if (context?.fn) console.error(`[${context.fn}]`, err)
  else console.error(err)
  const exception = err instanceof Error ? err : new Error(err?.message ?? JSON.stringify(err))
  Sentry.captureException(exception, { extra: { ...context, originalError: err } })
}
