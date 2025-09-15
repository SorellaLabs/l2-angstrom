# Compensation Price Calculation

![](./assets/pstar-solution-viz.png)

(Diagram: Visualization of solution for effective compensation price)

This note explains how the compensation price is determined when the price lies within the swap price range $p_\star \in [p_l, p_u]$.
## Variables & Definitions

- $ L_i > 0$: virtual liquidity for range $i$ ($L_i = \sqrt{x_i y_i}$ where $x_i, y_i$ are the virtual reserves for range $i$)
- $p_{i} > 0$ is the price of the lower boundary of range $i$
- $p_\star > 0$: post-trade effective compensation price
- $B > 0$ is the bid/liquidity compensation amount.
- Given some liquidity $L_i$ and a price $p$ we can determine the virtual reserves in $x$ & $y$ at that price point with: $x = L_i\cdot\frac{1}{\sqrt p}, y = L_i\cdot{\sqrt p}$
- To compute the net amount deltas required to cross a range $i$: $\Delta x_i =L_i(\frac{1}{\sqrt{p_i}}-\frac{1}{\sqrt{p_{i+1}}}),\ \Delta y_i = L_i(\sqrt{p_{i+1}}-\sqrt{p_i})$
- $\hat X, \hat Y > 0$: aggregated swap amount of whole ranges where the final $p_\star \notin [a_i, b_i]$ is known to lie outside of (where $a_i = \max\{p_i, p_{\text{start}}\}, b_i = \min\{p_{i+1}, p_{\text{end}}\}$, implicitly $a_i \le b_i$):
 
$$\hat X =\sum_i L_i(\frac{1}{\sqrt{a_i}}-\frac{1}{\sqrt{b_i}}),\qquad \hat Y = \sum_i L_i(\sqrt{b_i}-\sqrt{a_i}).$$

## Compensation Price definition

Assuming unsigned total deltas $X = \sum_i {\Delta x_i}, Y=\sum_i \Delta y_i$ the final compensation price $p_\star$ is defined as:

**Zero-for-One Swap:** $p_\star = \frac{Y}{X + B}$ such that each range $i$ trades $\Delta x'_i = \Delta y_i \cdot (\min \{p_\star, \frac{\Delta y_i}{\Delta x_i}\})^{-1}$

**One-for-Zero Swap:** $p_\star = \frac{Y}{X- B}$ such that each range $i$ trades $\Delta x'_i = \Delta y_i \cdot (\max \{p_\star, \frac{\Delta y_i}{\Delta x_i}\})^{-1}$



## Base Considered Swap Amount

Notice from the above definition that there will be a consecutive sub-set of ranges which will trade at ($p_\star \le \frac{\Delta y_i}{\Delta x_i}$ for zero-for-one, $p_\star \ge \frac{\Delta y_i}{\Delta x_i}$ for one-for-zero).

This range can be determined by walking from $p_{start} \rightarrow p_{end}$ and keeping track of the total sum so far $\hat X = \sum_i {\Delta x_i},\hat Y=\sum_i \Delta y_i$. At each step checking $\tilde p_i = \frac{\hat Y}{\hat X + B}/\tilde p_i = \frac{\hat Y}{\hat X - B} $ depending on the swap direction. If $\tilde p_i$ is outside of the current range the current range will be part of the consecutive set.

If all ranges are depleted and $\tilde p_{end}$ lies beyond $p_{end}$ then we can take $p_\star := \tilde p_{end}$.

Otherwise when a range is found such that $\tilde p_i \in [p_i, p_{i+1}]$ we need to calculate the actual $p_\star$ that satisfies our original formula.

## Case A — Zero-for-One (price decreasing)

### Setup
For a given tick $i$ that is being swapped through, we have:

$$\Delta x = L\left(\frac{1}{\sqrt{p_\star}}-\frac{1}{\sqrt{p_{i+1}}}\right),\qquad
\Delta y = L\cdot(\sqrt{p_{i+1}}-\sqrt{p_\star}),\qquad
B = \frac{\hat Y+\Delta y}{p_\star} - (\hat X+\Delta x).
$$

### Quadratic in $\sqrt{p_\star}$

Clearing denominators and simplifying yields:

$$ A \cdot(\sqrt{p_\star})^2 + 2L\cdot\sqrt{p_\star} - (\hat Y+y) = 0,\qquad A := B + \hat X - x $$

Solutions:

$$\sqrt{p_\star}=\frac{-L \pm \sqrt{L^2 + A(\hat Y+y)}}{A}
=\frac{-L \pm \sqrt{\hat Y\cdot(B+\hat X - x)+ y\cdot(B+\hat X)}}{B+\hat X - x}.$$

(The two radicands are equal because $L^2=xy$.)



### Existence & Uniqueness on $(0,u]$ (where $u=\sqrt{p_{i+1}}$)

The quadratic gives us two solutions, we now want to prove the theorem that:
> There exists one unique solution that lies in the range $(0, u]$ and that solution is given by:
> $$s_+ = \frac{-L + \sqrt{L^2 + A(\hat Y+y)}}{A}$$

Let's take the above quadratic as a function $\phi(s)$ s.t. $\phi(\sqrt{p_\star}) = 0$:

$$\phi(s) =A s^2 + 2Ls - (\hat Y+y)$$

#### Lemma 1: Monotonicity of $\phi(s)$ over $(0,u]$

We prove that $\phi(s)$ monotonically increases for $s \in (0, u]$ by showing that $\phi'(s) \ge 0$ in that range:

$\phi'(s) = 2As + 2L$

**$\phi'(0) \ge 0$:** $\phi'(0) = 2A(0) + 2L = 2L \Rightarrow \phi'(0) \ge 0$


**$\phi'(u) \ge 0$:**
- Expand $\phi'(u)$: $2Au + 2L \ge 0 \Leftrightarrow 2 (B + \tilde X - x)u \ge -2L$
- Prove tighter bound: $B + \tilde X - x \ge -x \Rightarrow 2(-x)u \ge -2L \Rightarrow 2Au \ge -2L$
- Use $u = \sqrt\frac{y}{x}$:$\quad 2 (-x)\sqrt{\frac{y}{x}} \ge -2\sqrt{xy} \Leftrightarrow x\sqrt\frac{y}{x} \le \sqrt{xy} \Leftrightarrow \sqrt{x^2 \frac{y}{x}}  = \sqrt{xy} $

#### Lemma 2: Boundary signs $\phi(0) < 0$ and $\phi(u) \ge 0$

$\phi(0) \lt 0$: $ - (\tilde Y + y) < 0 $
$\phi(u) \ge 0$:
- Expand $\phi(u)$: $Au^2+2Lu-(\tilde Y + y) \ge 0$
- Expand $A$ and simplify: $ (B + \hat X - x)u^2+2y-\tilde Y - y \ge 0 \Leftrightarrow (B + \tilde X)u^2  \ge 
\tilde Y$
- Reorganize & expand $u^2$: $p_{i+1} \ge \frac{\tilde Y}{B + \tilde X}$
- Recognize that $\tilde p = \frac{\tilde Y}{B + \tilde X}$ and that $p_{i+1} \ge \tilde p$ is the precondition for beginning this calculation

#### Lemma 3: Unique Solution in $(0,u]$

Using Lemma 1 & 2 and the Intermediate value theorem we now know that there is exactly one $s \in (0,u]$ s.t. $\phi(s) = 0$ and therefore only one solution to the quadratic in that range.

#### Lemma 4: $s_+$ is that solution

$$s_+ = \frac{-L + \sqrt{D}}{A}, D:=L^2 + A(\hat Y+y)$$
$$s_- = \frac{-L - \sqrt{D}}{A}, D:=L^2 + A(\hat Y+y)$$

**$A > 0$:** trivially $s_- < 0$, leaving $s_+$ as the only positive solution.

**$A < 0$:**
$$\frac{-L + \sqrt{L^2 + A(\hat Y+y)}}{A} > 0$$
$$\frac 1 A\sqrt{L^2 + A(\hat Y+y)} - \frac{L}{A} > 0$$
$$\frac 1 A\sqrt{{L^2} + {A(\hat Y+y)}} > \frac{L}{A} $$

- $A > 0$: $\sqrt{\frac{L^2}{A^2} + \frac{\hat Y+y}{A}}^2 > (\frac{L}{A})^2  \Leftrightarrow \frac{L^2}{A^2} + \frac{\hat Y+y}{A} > \frac{L^2}{A^2} \Leftrightarrow   \frac{\hat Y+y}{A} > 0$ (which is true because $\tilde Y, y, A > 0$)
- $A < 0$: $\sqrt{{L^2} + {A(\hat Y+y)}} < L$ Assuming solution is real ($D \ge 0$ in $\sqrt D$) then the inequality naturally holds because $(\tilde Y + y) > 0, A <0 \Rightarrow A(\tilde Y+y) < 0 \Rightarrow \sqrt {x^2 - \gamma} < x$
    - Now we need to prove $D \ge 0$:
        $${L^2} + {A(\hat Y+y)} \ge 0$$
        $${L^2} + A\hat Y+Ay \ge 0$$
        $${L^2} + A\hat Y+(\tilde X + B - x)y \ge 0$$
        $${L^2} + A\hat Y+(\tilde X + B)y - L^2 \ge 0$$
        $$(\tilde X + B)y \ge (-A)\hat Y$$
        $$\frac y {-A} \ge \frac{\tilde Y}{\tilde X + B}$$
        $$\frac y {x - (\tilde X + B)} \ge \tilde p$$
        Given $x>0, -A>0,\tilde X + B\ge0 \Rightarrow \frac y {x - (\tilde X + B)}\ge\frac{y}{x}$ therefore we know that proving the tighter inequality $\frac{y}{x} \ge \tilde p$, which is the precondition for this calculation, is equivalent to proving the original. Therefore $D \ge 0$

**$s_+ \le u$:**
$$\frac{-L + \sqrt{L^2 + A(\hat Y+y)}}{A} \le u$$










Let $\phi(\sqrt{p_\star}):=A \sqrt{p_\star}^2 + 2L\sqrt{p_\star} - (\hat Y+y)$. Then
$$\phi(0)=-(\hat Y+y) < 0,\qquad
\phi(\sqrt{p_{i+1}})= (B+\hat X - x)\sqrt{p_\star}^2 + 2L\sqrt{p_\star} - (\hat Y+y).$$

Using $2L\sqrt{p_\star}=2y$ and $x \sqrt{p_{i+1}}^2 = y$,
$$\phi(u)=(B+\hat X)\sqrt{p_{i+1}}^2 - \hat Y = \big(B - B_0^{\downarrow}\big)\sqrt{p_{i+1}}^2,\qquad
B_0^{\downarrow} := \frac{\hat Y}{\sqrt{p_{i+1}}^2} - \hat X \ (\ge 0 \text{ by } p_u\le \hat Y/\hat X).$$

Hence, if $\boxed{B \ \ge\ B_0^{\downarrow} := \frac{\hat Y}{\sqrt{p_{i+1}}^2} - \hat X}$
then $\phi(0)<0$ and $\phi(u)\ge 0$. Moreover,
$$\phi'(\sqrt{p_\star})=2A\sqrt{p_\star}+2L \ \ge\ 2(-x)\sqrt{p_\star}+2L = 2L\!\left(1-\frac{\sqrt{p_\star}}{\sqrt{p_{i+1}}}\right) > 0 \quad \text{for } \sqrt{p_\star}\in(0,\sqrt{p_{i+1}}],$$
since $A=B+\hat X-x>-x$. Therefore $\phi$ is **strictly increasing** on $(0,\sqrt{p_{i+1}}]$, giving **exactly one** root in $(0,\sqrt{p_{i+1}}]$.
