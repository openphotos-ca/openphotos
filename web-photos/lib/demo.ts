export const DEMO_EMAIL = 'demo@openphotos.ca';

export function isDemoEmail(email?: string | null): boolean {
  return (email ?? '').trim().toLowerCase() === DEMO_EMAIL;
}
