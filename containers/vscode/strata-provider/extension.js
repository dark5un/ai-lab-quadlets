'use strict';
// Strata (local llama.cpp-class server) provider for the VS Code model picker.
// Uses ONLY the stable LanguageModelChatProvider API as shipped in VS Code
// 1.104+ (verified against the pinned 1.144.1 bundle's vscode.d.ts).
// Models are discovered live from the server's GET /models, so strata
// re-slots (new model id, new n_ctx) need zero config changes here.

const vscode = require('vscode');

const VENDOR = 'strata';

function config() {
	const c = vscode.workspace.getConfiguration('strata');
	// baseUrl/apiKey/modelAllowlist are MACHINE-scope settings (package.json):
	// a workspace must not be able to redirect the auto-attached key.
	// Per-box overrides live in the server's data/Machine/settings.json.
	const base = (c.get('baseUrl') || 'http://127.0.0.1:8080/v1').replace(/\/+$/, '');
	return {
		base,
		apiKey: c.get('apiKey') || process.env.STRATA_API_KEY || '',
		contextWindow: c.get('contextWindow', 1048576),
		maxOutputTokens: c.get('maxOutputTokens', 16384),
		toolCalling: c.get('toolCalling', true),
		imageInput: c.get('imageInput', true),
		maxImageBytes: c.get('maxImageBytes', 10485760),
		allowlist: c.get('modelAllowlist', []) || [],
	};
}

// Error text stays debuggable but never echoes URL userinfo/query (finding #9).
function safeUrl(url) {
	try {
		const u = new URL(url);
		return u.origin + u.pathname;
	} catch {
		return '<invalid-url>';
	}
}

function abortSignal(token) {
	const controller = new AbortController();
	token.onCancellationRequested(() => controller.abort());
	return controller.signal;
}

async function fetchJson(url, apiKey, token, init) {
	const opts = Object.assign({}, init);
	const headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers);
	if (apiKey) {
		headers['Authorization'] = `Bearer ${apiKey}`;
	}
	opts.headers = headers;
	let res;
	try {
		res = await fetch(url, Object.assign(opts, { signal: abortSignal(token) }));
	} catch (e) {
		throw new Error(`strata: request to ${safeUrl(url)} failed: ${e && e.message ? e.message : e}`);
	}
	if (!res.ok) {
		let body = '';
		try { body = (await res.text()).slice(0, 400); } catch { /* ignore */ }
		throw new Error(`strata: ${safeUrl(url)} returned ${res.status} ${body}`);
	}
	return res;
}

function label(modelId) {
	return modelId.replace(/[_-]+/g, ' ').replace(/\b\w/g, ch => ch.toUpperCase());
}

class StrataProvider {

	async provideLanguageModelChatInformation(options, token) {
		const cfg = config();
		if (!cfg.apiKey) {
			if (options.silent) {
				return [];
			}
			throw new Error('strata: no API key. Set the strata.apiKey setting or the STRATA_API_KEY environment variable.');
		}
		const res = await fetchJson(`${cfg.base}/models`, cfg.apiKey, token);
		const data = (await res.json()).data || [];
		let models = data;
		if (cfg.allowlist.length) {
			models = models.filter(m => cfg.allowlist.includes(m.id));
		}
		return models.map(m => {
			const ctx = (m.meta && m.meta.n_ctx) || cfg.contextWindow;
			const modalities = m.architecture && m.architecture.input_modalities;
			const imageInput = Array.isArray(modalities) ? modalities.includes('image') : cfg.imageInput;
			const status = m.status && m.status.value ? m.status.value : 'unknown';
			return {
				id: m.id,
				name: label(m.id),
				family: m.id,
				version: status,
				tooltip: `strata @ ${cfg.base} (status: ${status}, n_ctx: ${ctx})`,
				maxInputTokens: Math.max(4096, ctx - cfg.maxOutputTokens),
				maxOutputTokens: cfg.maxOutputTokens,
				capabilities: {
					toolCalling: cfg.toolCalling,
					imageInput,
				},
			};
		});
	}

	async provideLanguageModelChatResponse(model, messages, options, progress, token) {
		const cfg = config();
		// Spread caller-/setting-supplied modelOptions FIRST, then re-pin the
		// transport-core fields last (finding #6): OpenAI-compatible extras
		// (temperature, top_p, seed...) pass through verbatim, but model,
		// messages and stream can never be overridden.
		const body = Object.assign({}, (options && options.modelOptions) || {});
		if (body.max_tokens == null) {
			body.max_tokens = cfg.maxOutputTokens;
		}
		const skippedImages = [];
		body.model = model.id;
		body.messages = convertMessages(messages, cfg.maxImageBytes, skippedImages);
		body.stream = true;
		if (skippedImages.length) {
			progress.report(new vscode.LanguageModelTextPart(
				`[strata: skipped ${skippedImages.length} image input(s) over ${Math.round(cfg.maxImageBytes / 1024)} KB — raise strata.maxImageBytes to allow them]`));
		}
		const tools = options && options.tools;
		if (tools && tools.length) {
			body.tools = tools.map(t => ({
				type: 'function',
				function: {
					name: t.name,
					description: t.description || '',
					parameters: t.inputSchema || { type: 'object', properties: {} },
				},
			}));
			if (options.toolMode === vscode.LanguageModelChatToolMode.Required) {
				body.tool_choice = 'required';
			}
		}

		const res = await fetchJson(`${cfg.base}/chat/completions`, cfg.apiKey, token, {
			method: 'POST',
			headers: { 'Accept': 'text/event-stream' },
			body: JSON.stringify(body),
		});

		// Parse the SSE stream; accumulate tool-call argument fragments by index.
		const toolCalls = new Map();
		let finishReason;
		const reader = res.body.getReader();
		const decoder = new TextDecoder();
		let buffer = '';
		for (;;) {
			const { done, value } = await reader.read();
			if (done) {
				break;
			}
			buffer += decoder.decode(value, { stream: true });
			let idx;
			while ((idx = buffer.indexOf('\n')) >= 0) {
				const line = buffer.slice(0, idx).trim();
				buffer = buffer.slice(idx + 1);
				if (!line.startsWith('data:')) {
					continue;
				}
				const payload = line.slice(5).trim();
				if (payload === '[DONE]') {
					continue;
				}
				let chunk;
				try {
					chunk = JSON.parse(payload);
				} catch {
					continue; // keep-alive or partial line
				}
				const choice = chunk.choices && chunk.choices[0];
				if (!choice) {
					continue;
				}
				const delta = choice.delta || {};
				if (typeof delta.content === 'string' && delta.content.length) {
					progress.report(new vscode.LanguageModelTextPart(delta.content));
				}
				// delta.reasoning_content is intentionally NOT reported: the
				// thinking-part class is a proposed API here, and leaking it as
				// text mixes internal reasoning into answers.
				if (Array.isArray(delta.tool_calls)) {
					for (const tc of delta.tool_calls) {
						const slot = toolCalls.get(tc.index || 0) || { id: '', name: '', args: '' };
						if (tc.id) {
							slot.id = tc.id;
						}
						if (tc.function && tc.function.name && tc.function.name !== slot.name) {
							// Accumulate chunked names; skip an exact repeat of
							// what we already have — some servers resend the
							// full name in every delta (finding #11).
							slot.name += tc.function.name;
						}
						if (tc.function && typeof tc.function.arguments === 'string') {
							slot.args += tc.function.arguments;
						}
						toolCalls.set(tc.index || 0, slot);
					}
				}
				if (choice.finish_reason) {
					finishReason = choice.finish_reason;
				}
			}
		}
		for (const slot of toolCalls.values()) {
			let input = {};
			try {
				input = slot.args ? JSON.parse(slot.args) : {};
			} catch {
				input = { raw: slot.args };
			}
			progress.report(new vscode.LanguageModelToolCallPart(
				slot.id || `call_${Math.random().toString(36).slice(2, 10)}`,
				slot.name,
				input,
			));
		}
		if (finishReason === 'length') {
			throw new Error(`strata: response truncated at max_tokens (${cfg.maxOutputTokens}); raise strata.maxOutputTokens if thinking eats the budget.`);
		}
	}

	async provideTokenCount(model, text, token) {
		const s = typeof text === 'string' ? text : JSON.stringify(text);
		return Math.ceil(s.length / 4);
	}
}

function convertMessages(messages, maxImageBytes, skippedImages) {
	const out = [];
	for (const m of messages) {
		const texts = [];
		const images = [];
		const calls = [];
		const results = [];
		for (const p of m.content || []) {
			if (p instanceof vscode.LanguageModelTextPart) {
				texts.push(p.value);
			} else if (p instanceof vscode.LanguageModelToolCallPart) {
				calls.push(p);
			} else if (p instanceof vscode.LanguageModelToolResultPart) {
				results.push(p);
			} else if (p instanceof vscode.LanguageModelDataPart && (p.mimeType || '').startsWith('image/')) {
				const bytes = Buffer.from(p.data);
				if (maxImageBytes > 0 && bytes.byteLength > maxImageBytes) {
					// size cap keeps memory and request bodies bounded (#10);
					// images are otherwise re-encoded and resent every turn.
					skippedImages.push(p.mimeType);
					continue;
				}
				images.push(`data:${p.mimeType};base64,${bytes.toString('base64')}`);
			}
		}
		// Tool results ride on user messages but must become their own
		// role:"tool" messages in the OpenAI shape.
		for (const r of results) {
			out.push({
				role: 'tool',
				tool_call_id: r.callId,
				content: (r.content || [])
					.map(c => c instanceof vscode.LanguageModelTextPart ? c.value
						: typeof c === 'string' ? c : '')
					.join('\n'),
			});
		}
		if (m.name === 'system') {
			out.push({ role: 'system', content: texts.join('\n') });
			continue;
		}
		if (m.role === vscode.LanguageModelChatMessageRole.Assistant) {
			const msg = { role: 'assistant', content: texts.length ? texts.join('') : null };
			if (calls.length) {
				msg.tool_calls = calls.map(c => ({
					id: c.callId,
					type: 'function',
					function: { name: c.name, arguments: JSON.stringify(c.input || {}) },
				}));
			}
			out.push(msg);
			continue;
		}
		const textJoined = texts.join('');
		if (images.length) {
			out.push({
				role: 'user',
				content: [
					...(textJoined ? [{ type: 'text', text: textJoined }] : []),
					...images.map(url => ({ type: 'image_url', image_url: { url } })),
				],
			});
		} else {
			out.push({ role: 'user', content: textJoined });
		}
	}
	return out;
}

function activate(context) {
	// Visible in the browser devtools console for serve-web (and to the CDP
	// smoke driver in the e2e container); cheap activation proof.
	console.info('[strata-provider] activated; models discovered on demand from strata /models');
	context.subscriptions.push(
		vscode.lm.registerLanguageModelChatProvider(VENDOR, new StrataProvider())
	);
}

module.exports = { activate };
