export type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'silent'

function currentLevel(): LogLevel {
  const v = process.env.NEXT_PUBLIC_LOG_LEVEL?.toLowerCase() as LogLevel | undefined
  return v || (process.env.NODE_ENV === 'production' ? 'warn' : 'debug')
}

function levelOrder(l: LogLevel): number {
  switch (l) {
    case 'debug': return 10
    case 'info': return 20
    case 'warn': return 30
    case 'error': return 40
    case 'silent': return 100
  }
}

function enabled(min: LogLevel): boolean {
  return levelOrder(currentLevel()) <= levelOrder(min)
}

export const logger = {
  debug: (...args: any[]) => { if (enabled('debug')) console.debug(...args) },
  info:  (...args: any[]) => { if (enabled('info'))  console.log(...args) },
  warn:  (...args: any[]) => { if (enabled('warn'))  console.warn(...args) },
  error: (...args: any[]) => { if (enabled('error')) console.error(...args) },
}

