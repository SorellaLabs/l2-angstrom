# P* within range calculation

![](./assets/pstar-solution-viz.png)

This note explains which quadratic root is valid for computing the post-trade price $p_\star$ in both zero-for-one (price decreasing) and one-for-zero (price increasing) swaps. 

## Variables and Standing Assumptions

- $L \equiv L_i > 0$: virtual liquidity for tick $i$
- $p_i$ is the price of the lower boundary of tick $i$
- $\hat X, \hat Y > 0$: aggregated real reserves across all active ticks in the swap:
  $$
  \hat X = \sum_i L_i\!\left(\frac{1}{\sqrt{a_i}}-\frac{1}{\sqrt{b_i}}\right),\qquad
  \hat Y = \sum_i L_i\!\left(\sqrt{b_i}-\sqrt{a_i}\right).
  $$
where $a_i = \max\{p_i, p_{\text{start}}\}, b_i = \min\{p_{i+1}, p_{\text{end}}\}$
- $p_\star > 0$: post-trade price.
- Segment bounds within a given tick $i$:
  - **Zero-for-one** (price decreases): upper boundary $p_u=  p_{i+1}$.
  - **One-for-zero** (price increases): lower boundary $p_{l} = p_i$.
- Per-tick virtual reserves for zero-for-one at the upper boundary (one-for-zero is analogous)
  $$
  x := \frac{L_i}{\sqrt{p_{i+1}}},\qquad y := L_i\,\sqrt{p_{i+1}},\qquad\text{so } L_i^2 = x\,y.
  $$
- $B$ is the signed bid/budget appearing in the bookkeeping equation. We only assume the requested trade is feasible inside the current tick.

---

## Case A — Zero-for-One (price decreasing; target $p_\star \in (0, p_u]$)

### Setup
For a given tick $i$ that is being swapped through, we have:
$$
\Delta x = L\!\left(\frac{1}{\sqrt{p_\star}}-\frac{1}{\sqrt{p_{i+1}}}\right),\qquad
\Delta y = L\,(\sqrt{p_{i+1}}-\sqrt{p_\star}),\qquad
B = \frac{\hat Y+\Delta y}{p_\star} - (\hat X+\Delta x).
$$

### Quadratic in $\sqrt{p_\star}$

Clearing denominators and simplifying yields
$$
A\,(\sqrt{p_\star})^2 + 2L\,\sqrt{p_\star} - (\hat Y+y) = 0,\qquad A := B + \hat X - x.
\tag{Z1}$$

Solutions:
$$
\sqrt{p_\star}=\frac{-L \pm \sqrt{\,L^2 + A(\hat Y+y)\,}}{A}
=\frac{-L \pm \sqrt{\,\hat Y(\,B+\hat X - x\,)+ y(\,B+\hat X\,)\,}}{\,B+\hat X - x\,}.
\tag{Z2}$$

(The two radicands are equal because $L^2=xy$.)

### Existence & Uniqueness on $(0,u]$

Let $\phi(\sqrt{p_\star}):=A \sqrt{p_\star}^2 + 2L\sqrt{p_\star} - (\hat Y+y)$. Then
$$
\phi(0)=-(\hat Y+y) < 0,\qquad
\phi(\sqrt{p_{i+1}})= (B+\hat X - x)\sqrt{p_\star}^2 + 2L\sqrt{p_\star} - (\hat Y+y).
$$

Using $2L\sqrt{p_\star}=2y$ and $x \sqrt{p_{i+1}}^2 = y$,
$$
\phi(u)=(B+\hat X)\sqrt{p_{i+1}}^2 - \hat Y = \big(B - B_0^{\downarrow}\big)\sqrt{p_{i+1}}^2,\qquad
B_0^{\downarrow} := \frac{\hat Y}{\sqrt{p_{i+1}}^2} - \hat X \ (\ge 0 \text{ by } p_u\le \hat Y/\hat X).
$$

Hence, if 
$$
\boxed{\,B \ \ge\ B_0^{\downarrow} := \frac{\hat Y}{\sqrt{p_{i+1}}^2} - \hat X\,}
\tag{Z-Exist}$$
then $\phi(0)<0$ and $\phi(u)\ge 0$. Moreover,
$$
\phi'(\sqrt{p_\star})=2A\sqrt{p_\star}+2L \ \ge\ 2(-x)\sqrt{p_\star}+2L = 2L\!\left(1-\frac{\sqrt{p_\star}}{\sqrt{p_{i+1}}}\right) > 0 \quad \text{for } \sqrt{p_\star}\in(0,\sqrt{p_{i+1}}],
$$
since $A=B+\hat X-x>-x$. Therefore $\phi$ is **strictly increasing** on $(0,\sqrt{p_{i+1}}]$, giving **exactly one** root in $(0,\sqrt{p_{i+1}}]$.