# Angstrom L2

This repository contains the core contracts for the L2 Angstrom hook.

## Effective Execution Price Math

### Zero-for-One Swap (Price Decreasing)

**Solve Following System of Equations for $\sqrt {p_*}$**

$$ \Delta x = L_i \cdot (\frac {1} {\sqrt {p_*}} - \frac {1}{\sqrt {p_u}}) $$
$$ \Delta y = L_i \cdot (\sqrt{p_u} - \sqrt{p_*}) $$
$$ B = (\hat Y + \Delta y) \cdot \frac {1}{p_*} - (\hat X + \Delta x)$$ 

**Result:**

$$ \sqrt{p_*} = \frac {-L_i \pm \sqrt {\hat Y \cdot (B + \hat X - x) + y \cdot (B + \hat X)}} { B + \hat X -x }$$

### One-for-Zero Swap (Price Increasing)

**Solve Following System of Equations for $\sqrt {p_*}$**

$$ \Delta x = L_i \cdot (\frac {1} {\sqrt {p_l}} - \frac {1}{\sqrt {p_*}}) $$
$$ \Delta y = L_i \cdot (\sqrt{p_*} - \sqrt{p_li}) $$
$$ B = (\hat X + \Delta x) -  (\hat Y + \Delta y) \cdot \frac {1}{p_*}$$ 

**Result:**

$$ \sqrt{p_*} = \frac {L_i \pm \sqrt {\hat Y\cdot(\hat X + x - B ) - y \cdot (\hat X - B)}} { \hat X + x - B }$$
