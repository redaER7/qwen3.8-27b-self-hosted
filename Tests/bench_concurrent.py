import asyncio, aiohttp, json, random, time, statistics

MODEL = "Qwen/Qwen3.8-27B-FP8"
URL = "https://llm.yacodata.com/v1/chat/completions"
CONCURRENCY = 5
TTFT_COUNT = 2
MAX_TOKENS_MIN = 300
MAX_TOKENS_MAX = 1800

PROMPTS = [
    "Compute the Fourier transform of f(x)=e^{-⟨Ax,x⟩} for A∈C^{n×n}, Re A positive definite.",
    "Prove the Paley-Wiener characterization of FE'(B(0,R))(Rⁿ).",
    "A belt-driven wheel radius 30 cm spins at 300 rpm. Find angular velocity and belt speed.",
    "Wind turbine with 30m blades spins at 22 rpm. Find angular velocity and blade tip tangential velocity.",
    "Compute complex Fourier coefficients of a 2π-periodic rectangular pulse f(x)=1 for |x|<δ, 0 for δ≤|x|≤π.",
    "Analyze the Gibbs phenomenon for a square wave — show the overshoot approaches ≈8.9% as N→∞.",
    "A laboratory cart (500g) rests on a level track, connected to a lead weight (100g) suspended vertically off a pulley. Find the acceleration assuming negligible friction.",
    "If the Fourier transform F : Lᵖ(Rⁿ) → Lᵠ(Rⁿ) is continuous, prove that 1≤p≤2 and 1/q+1/p=1.",
    "Show that if f : R→C extends to a holomorphic function on a strip with an integrable bound, then its Fourier transform decays exponentially.",
    "Let A consist of functions holomorphic in a strip with certain growth conditions. Show that the Fourier transform maps A onto entire functions with exponential decay.",
    "Recall the proof that if f ∈ L¹(Rⁿ) then its Fourier transform f̂ ∈ C₀(Rⁿ). Sketch the key steps: density of Schwartz functions, uniform continuity, and the Riemann-Lebesgue lemma.",
    "Give two proofs that FL¹ ≠ C₀: (1) For odd f̂ ∈ L¹ show |∫₁ᵇ f̂(x)/x dx| ≤ A uniformly, then prove g(x)=tanh(x)/log(1+|x|) ∈ C₀\\FL¹. (2) Show (L¹,*) is a Banach algebra but not C*-algebra, while (C₀,·) is a C*-algebra.",
    "Derive the Euler-Lagrange equations for a functional of the form J[y] = ∫ F(x, y, y') dx with fixed endpoints.",
    "Compute the singular value decomposition of the matrix A = [[1, 2], [2, 1], [3, 4]].",
    "A particle moving in a central potential V(r) = -k/r has angular momentum L. Derive the effective potential and find conditions for circular orbits.",
    "Prove the spectral theorem for compact self-adjoint operators on a Hilbert space.",
    "Show that the alternating harmonic series ∑_{n=1}^{∞} (-1)^{n+1}/n converges to ln(2) and estimate the error after N terms.",
    "Using the method of characteristics, solve the PDE: u_x + x u_y = 0 with u(0, y) = y².",
    "Let f(x)=∑_{n=1}^{∞} sin(nx)/n². Determine if f is continuous, differentiable, and compute its Fourier series.",
    "Prove using the intermediate value property that every continuous function on a closed bounded interval attains its maximum and minimum.",
]

def percentile(data, p):
    if not data:
        return 0
    s = sorted(data)
    k = max(0, min(len(s) - 1, int(len(s) * p / 100)))
    return s[k]

def fmt_pct(data):
    if not data:
        return "  —"
    return f"min {min(data):.1f}s  p50 {percentile(data, 50):.1f}s  p95 {percentile(data, 95):.1f}s  max {max(data):.1f}s"

async def send_request(session, idx, payload):
    start = time.monotonic()
    try:
        async with session.post(URL, json=payload) as resp:
            body = await resp.json()
            elapsed = time.monotonic() - start
            usage = body.get("usage", {})
            tokens = usage.get("completion_tokens", 0)
            return {
                "idx": idx,
                "max_tokens": payload["max_tokens"],
                "duration": elapsed,
                "tokens": tokens,
                "tok_s": tokens / elapsed if elapsed > 0 and tokens else 0,
                "status": resp.status,
                "error": None,
            }
    except Exception as e:
        elapsed = time.monotonic() - start
        return {
            "idx": idx,
            "max_tokens": payload["max_tokens"],
            "duration": elapsed,
            "tokens": 0,
            "tok_s": 0,
            "status": 0,
            "error": str(e),
        }

async def send_streaming_ttft(session, idx, payload):
    start = time.monotonic()
    try:
        p = {**payload, "stream": True}
        async with session.post(URL, json=p) as resp:
            ttft = None
            while True:
                line = await resp.content.readline()
                if not line:
                    break
                line = line.strip()
                if line.startswith(b"data: [DONE]"):
                    break
                if line.startswith(b"data: "):
                    if ttft is None:
                        ttft = time.monotonic() - start
                    break
            return {
                "idx": idx,
                "ttft": ttft,
                "status": resp.status,
                "error": None,
            }
    except Exception as e:
        return {
            "idx": idx,
            "ttft": None,
            "status": 0,
            "error": str(e),
        }

async def main():
    timeout = aiohttp.ClientTimeout(total=600)
    connector = aiohttp.TCPConnector(limit=max(CONCURRENCY, TTFT_COUNT))

    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        print(f"Benchmark: {CONCURRENCY} concurrent requests to {URL}")
        print(f"Model: {MODEL}")
        print(f"TTFT probes: {TTFT_COUNT}  |  max_tokens: {MAX_TOKENS_MIN}–{MAX_TOKENS_MAX}")
        print()

        print("─ TTFT (streaming) ─────────────────────────────────────")
        ttft_tasks = []
        for i in range(TTFT_COUNT):
            payload = {
                "model": MODEL,
                "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}],
                "max_tokens": random.randint(MAX_TOKENS_MIN, MAX_TOKENS_MAX),
            }
            ttft_tasks.append(send_streaming_ttft(session, i + 1, payload))

        ttft_results = await asyncio.gather(*ttft_tasks)
        ttft_vals = []
        for r in ttft_results:
            s = f"{r['ttft']:.2f}s" if r["ttft"] and r["status"] == 200 else f"ERR({r.get('error', r['status'])})"
            print(f"  #{r['idx']:>2}  TTFT = {s}")
            if r["ttft"] and r["status"] == 200:
                ttft_vals.append(r["ttft"])

        print()
        print(f"  TTFT: {fmt_pct(ttft_vals)}")
        print()

        print("─ Throughput (non-streaming) ───────────────────────────")
        tasks = []
        for i in range(CONCURRENCY):
            payload = {
                "model": MODEL,
                "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}],
                "max_tokens": random.randint(MAX_TOKENS_MIN, MAX_TOKENS_MAX),
            }
            tasks.append(send_request(session, i + 1, payload))

        results = await asyncio.gather(*tasks)

        header = f"{'#':>2}  {'max_tok':>7}  {'duration':>8}  {'tokens':>6}  {'tok/s':>8}  {'status':>6}"
        sep = "─" * len(header)
        print(header)
        print(sep)

        durations = []
        tok_rates = []
        tok_counts = []
        errors = 0

        for r in sorted(results, key=lambda x: x["idx"]):
            status_str = f"{r['status']}" if r["status"] == 200 else f"ERR({r['error']})"
            print(f"{r['idx']:>2}  {r['max_tokens']:>7}  {r['duration']:>8.1f}s  {r['tokens']:>6}  {r['tok_s']:>8.1f}  {status_str:>6}")
            if r["status"] == 200:
                durations.append(r["duration"])
                tok_rates.append(r["tok_s"])
                tok_counts.append(r["tokens"])
            else:
                errors += 1

        print()
        print("─ Summary ──────────────────────────────────────────────")
        print(f"  Success:  {CONCURRENCY - errors}/{CONCURRENCY}  ({100 * (CONCURRENCY - errors) / CONCURRENCY:.0f}%)  |  {errors} errors")

        if durations:
            success_count = len(durations)
            total_tokens = sum(tok_counts)
            total_time = max(durations)
            throughput_req = success_count / total_time
            throughput_tok = total_tokens / total_time

            print(f"  Throughput:  {throughput_req:.1f} req/s  |  {throughput_tok:.0f} tok/s")
            print(f"  Latency:     {fmt_pct(durations)}")
            print(f"  Tokens/req:  min {min(tok_counts)}  p50 {percentile(tok_counts, 50):.0f}  p95 {percentile(tok_counts, 95):.0f}  max {max(tok_counts)}")
            print(f"  Tok/s:       min {min(tok_rates):.1f}  p50 {percentile(tok_rates, 50):.1f}  p95 {percentile(tok_rates, 95):.1f}  max {max(tok_rates):.1f}")

if __name__ == "__main__":
    asyncio.run(main())
