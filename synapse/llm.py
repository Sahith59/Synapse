import time
from typing import List

# Llama-3.2-3B-Instruct (4-bit) produces coherent, grounded answers on Apple MLX.
# The previously-used Phi-3-mini-4bit emitted broken tokens with this mlx-lm
# version, so it was replaced.
MODEL_NAME = "mlx-community/Llama-3.2-3B-Instruct-4bit"

# Generation settings. Low temperature keeps answers faithful to the context.
MAX_TOKENS = 256
TEMPERATURE = 0.2


class RAGEngine:
    def __init__(self):
        self.model = None
        self.tokenizer = None
        self._generate = None
        self._make_sampler = None
        self._is_loading = False
        self._mlx_available = None

    def _ensure_mlx(self):
        if self._mlx_available is None:
            try:
                from mlx_lm import load, generate  # noqa: F401
                self._mlx_available = True
            except ImportError:
                self._mlx_available = False
        return self._mlx_available

    def _ensure_model_loaded(self):
        if not self._ensure_mlx():
            raise RuntimeError("mlx-lm is not installed. RAG generation is unavailable.")

        if self.model is None and not self._is_loading:
            self._is_loading = True
            print(f"[RAG] Lazy-loading {MODEL_NAME} into MLX...", flush=True)
            t0 = time.perf_counter()
            from mlx_lm import load, generate
            from mlx_lm.sample_utils import make_sampler
            self.model, self.tokenizer = load(MODEL_NAME)
            self._generate = generate
            self._make_sampler = make_sampler
            t1 = time.perf_counter()
            print(f"[RAG] Model loaded into Unified Memory in {t1 - t0:.2f}s", flush=True)
            self._is_loading = False

    def ask(self, query: str, context_snippets: List[str]) -> str:
        self._ensure_model_loaded()

        if not context_snippets:
            return "I don't have any relevant memories about that yet."

        # Number each snippet so the model can ground its answer in specific items.
        context_block = "\n".join(
            f"[{i+1}] {text.strip()}" for i, text in enumerate(context_snippets)
        )

        system_msg = (
            "You are Synapse, a personal memory assistant on the user's Mac. "
            "Each memory snippet is something the user actually saw or did on their "
            "computer: a web page they visited, a search they ran, a note they wrote, "
            "an email they read. Treat the snippets as factual evidence of the user's "
            "activity. For example, a captured Google search result for 'X' means the "
            "user did search for X.\n\n"
            "Answer the user's question directly in one or two natural sentences, based "
            "on the snippets. Reference what the snippet shows (the page, the search, "
            "the note). Do not dump the raw snippet or URL. Only say you have no memory "
            "of something if none of the snippets are relevant to the question."
        )
        user_msg = (
            f"My captured memories:\n{context_block}\n\n"
            f"Question: {query}"
        )

        messages = [
            {"role": "system", "content": system_msg},
            {"role": "user", "content": user_msg},
        ]
        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

        print(f"[RAG] Generating response for query: '{query}'...", flush=True)
        t0 = time.perf_counter()

        sampler = self._make_sampler(temp=TEMPERATURE)
        response = self._generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            verbose=False,
            max_tokens=MAX_TOKENS,
            sampler=sampler,
        )

        t1 = time.perf_counter()
        print(f"[RAG] Generated {len(response)} chars in {t1 - t0:.2f}s", flush=True)

        return response.strip()

    def digest(self, snippets: List[str]) -> str:
        """Summarize a window of captured memories into a short narrative."""
        self._ensure_model_loaded()
        if not snippets:
            return "No memories to summarize yet."

        context_block = "\n".join(f"- {s.strip()[:300]}" for s in snippets)
        system_msg = (
            "You are Synapse, a personal memory assistant. The user gives you a list "
            "of things they saw and did on their Mac today (web pages, searches, "
            "notes, emails). Write a brief, friendly summary of their day in 2-4 "
            "sentences — what they focused on and any themes. Be specific but concise, "
            "and do not list every item or include URLs."
        )
        messages = [
            {"role": "system", "content": system_msg},
            {"role": "user", "content": f"Today's activity:\n{context_block}\n\nSummarize my day:"},
        ]
        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

        print(f"[RAG] Generating daily digest from {len(snippets)} memories...", flush=True)
        t0 = time.perf_counter()
        sampler = self._make_sampler(temp=0.4)
        response = self._generate(
            self.model, self.tokenizer, prompt=prompt,
            verbose=False, max_tokens=220, sampler=sampler,
        )
        print(f"[RAG] Digest generated in {time.perf_counter() - t0:.2f}s", flush=True)
        return response.strip()


# Singleton instance
rag_engine = RAGEngine()
