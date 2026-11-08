// Web Worker that runs the WebLLM engine off the main thread so the page stays smooth while it thinks.
// The page talks to it through WebWorkerMLCEngine (see webllm.js).

import { WebWorkerMLCEngineHandler } from '../../vendor/web-llm/index.js';

const handler = new WebWorkerMLCEngineHandler();
self.onmessage = (msg) => handler.onmessage(msg);
