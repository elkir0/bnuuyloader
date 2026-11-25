#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the real source-family selector and retained legacy archive."""
from pathlib import Path
import runpy

package = Path(__file__).resolve().parent.parent
module = runpy.run_path(str(package / 'bin/omamobile-omarchy-patches'))
select = module['default_series']

assert select('/fixture', [('omarchy', '4.0.6-2', None)]).endswith('/legacy-4.0.6')
assert select('/fixture', [('omarchy', '4.5.0-3', None)]).endswith('/patches')
try:
    select('/fixture', [('omarchy', '4.6.0-1', None)])
except module['Failure']:
    pass
else:
    raise AssertionError('unsupported source family accepted')

# The tablet drops seven phone-only patches from each family and adds two
# tablet ones (9000/9001): 29 - 7 + 2 = 24. The SM-T715 build adds one more to
# the 4.5 family (9002-t715-lock-blank-through-keys): 25.
assert len(list((package / 'legacy-4.0.6').glob('*.patch'))) == 24
assert len(list((package / 'patches').glob('*.patch'))) == 25
print('PASS: actual selector rejects unsupported families; tablet series sizes hold')
