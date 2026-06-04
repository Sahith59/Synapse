import time
from typing import List

MODEL_NAME = "mlx-community/Phi-3-mini-4k-instruct-4bit"

class RAGEngine:
    def __init__(self):
        self.model = None
        self.tokenizer = None
        self._generate = None
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
            self.model, self.tokenizer = load(MODEL_NAME)
            self._generate = generate
            t1 = time.perf_counter()
            print(f"[RAG] Model loaded into Unified Memory in {t1 - t0:.2f}s", flush=True)
            self._is_loading = False

    def ask(self, query: str, context_snippets: List[str]) -> str:
        self._ensure_model_loaded()

        if not context_snippets:
            return "I don't have any relevant memories about that."

        context_block = "\n\n".join([f"[{i+1}] {text}" for i, text in enumerate(context_snippets)])

        system_msg = (
            "You are Synapse, a personal AI assistant on a Mac. Answer the user's "
            "question concisely using ONLY the provided memory context. If the answer "
            "is not in the context, say you don't know."
        )
        user_msg = (
            f"--- MEMORY CONTEXT ---\n{context_block}\n----------------------\n\n"
            f"Question: {query}"
        )

        # Use the model's chat template so Phi-3 gets its expected control tokens
        messages = [
            {"role": "system", "content": system_msg},
            {"role": "user", "content": user_msg},
        ]
        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

        print(f"[RAG] Generating response for query: '{query}'...", flush=True)
        t0 = time.perf_counter()

        from mlx_lm.sample_utils import make_sampler
        sampler = make_sampler(temp=0.3)
        response = self._generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            verbose=False,
            max_tokens=256,
            sampler=sampler,
        )

        t1 = time.perf_counter()
        print(f"[RAG] Generated {len(response)} chars in {t1 - t0:.2f}s", flush=True)

        return response.strip()

# Singleton instance
rag_engine = RAGEngine()
