/* ============================================================
 * Haramball — environment configuration
 * ------------------------------------------------------------
 * Auto-detects which environment the site is running in and
 * picks the matching Supabase credentials.
 *
 *   production  → haramball.com    → production Supabase
 *   staging     → *.pages.dev      → staging Supabase
 *
 * The anon keys are safe to commit publicly — Row Level Security
 * on the database protects all writes.
 * ============================================================ */

(function () {
  const host = (typeof window !== 'undefined' && window.location && window.location.hostname) || '';

  // PRODUCTION: haramball.com
  const PRODUCTION = {
    SUPABASE_URL:      'https://wolleqnvaonerzsomzvd.supabase.co',
    SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndvbGxlcW52YW9uZXJ6c29tenZkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgzNTE1NTUsImV4cCI6MjA5MzkyNzU1NX0.eIG9qK4SdTsO3V5KVazvSCDZGKJ-9dN1w9ql5akNQ6M',
    ENV: 'production'
  };

  // STAGING: *.pages.dev preview deployments and local development
  const STAGING = {
    SUPABASE_URL:      'https://psoqcvpxnvbmffbzbzbv.supabase.co',
    SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBzb3FjdnB4bnZibWZmYnpiemJ2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4OTU0MTgsImV4cCI6MjA5NDQ3MTQxOH0.fTBAxCx8hJ2phZsp0ZwPnWmzEoN1xFknn5kX4zAxPn4',
    ENV: 'staging'
  };

  // ----- Detection -----
  const isLocal    = host === 'localhost' || host === '127.0.0.1' || host === '';
  const isPagesDev = host.endsWith('.pages.dev');

  // Anything on *.pages.dev or local = staging. Otherwise production.
  const config = (isPagesDev || isLocal) ? STAGING : PRODUCTION;

  window.HARAMBALL_CONFIG = config;

  // ----- Visible STAGING badge so the environment is unmistakable -----
  if (config.ENV !== 'production') {
    const showBadge = () => {
      if (!document.body) { setTimeout(showBadge, 50); return; }
      const badge = document.createElement('div');
      badge.textContent = 'STAGING';
      badge.style.cssText = [
        'position:fixed', 'top:8px', 'left:8px', 'z-index:99999',
        'background:#d63031', 'color:#fff', 'padding:4px 10px',
        'border-radius:4px', 'font-family:monospace', 'font-size:11px',
        'font-weight:700', 'letter-spacing:1px',
        'box-shadow:0 2px 8px rgba(0,0,0,0.3)', 'pointer-events:none'
      ].join(';');
      document.body.appendChild(badge);
    };
    showBadge();
  }

  if (typeof console !== 'undefined') {
    console.log('[haramball]', config.ENV.toUpperCase(), 'on', host);
  }
})();