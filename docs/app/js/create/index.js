// Create module: registers the character creator (#/create) and editor (#/create/:id). The profile page's
// "Edit" button links to #/create?edit=<id>, which the same page handles.

import { registerRoute } from '../router.js';
import { renderCreate } from './create.js';

registerRoute('/create', renderCreate, { title: 'Create' });
registerRoute('/create/:id', renderCreate, { title: 'Edit character' });
