"""JSON at the app's edges.

A `JsonObject` is a JSON object as an MCP tool, a REST call or the catalogue
hands it over: string keys, values of any JSON type. The name marks where data
crosses that boundary; its values are not type-checked, so check or cast them
before they flow into typed code.
"""

type JsonObject = dict[str, any];  # jac:ignore[W2003]: used by the modules that import it
