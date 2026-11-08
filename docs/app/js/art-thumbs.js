// Web-sized JPEG copies of docs/assets/art live in docs/app/img/art/ (sips -s format jpeg -Z 384 for char-*, -Z 800 for loc-*/hero-*).
// Regenerate them when the art changes. Assets not listed here load the full PNG from docs/assets/art.

export const ART_THUMBS = new Set([
  'char-ada',
  'char-agnes',
  'char-bea',
  'char-dana',
  'char-ezra',
  'char-felix',
  'char-iris',
  'char-juno',
  'char-kai',
  'char-luna',
  'char-mika',
  'char-nora',
  'char-pip',
  'char-sol',
  'char-theo',
  'char-wren',
  'hero-night',
  'hero-town',
  'loc-arcade',
  'loc-driftwood-cafe',
  'loc-greenhouse',
  'loc-harbor',
  'loc-lighthouse',
  'loc-night-market',
  'loc-observatory',
  'loc-tidepool-library'
]);
