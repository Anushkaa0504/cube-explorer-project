"""
`globals.py` is auto-loaded by Cube when present alongside the data model.
Anything you assign to `template.add_variable(...)` becomes accessible inside
Jinja templates (`{{ my_var }}`).

Here we expose helper functions you can reuse across cubes.
"""

from cube import TemplateContext

template = TemplateContext()


@template.function('with_prefix')
def with_prefix(name: str, prefix: str = '') -> str:
    """Render `prefix_name` when prefix is provided, else just `name`."""
    return f"{prefix}_{name}" if prefix else name
