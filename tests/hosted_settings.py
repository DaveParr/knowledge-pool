"""Stand-in WorkOS settings for tests that start the app in hosted mode. No
test talks to WorkOS: these only have to be present."""

HOSTED_SETTINGS = {
    "KP_AUTHKIT_DOMAIN": "https://stand-in.authkit.app",
    "KP_MCP_URL": "https://knowledge-pool.example/mcp",
    "WORKOS_CLIENT_ID": "client_stand_in",
    "WORKOS_API_KEY": "sk_stand_in",
    "WORKOS_COOKIE_PASSWORD": "a-stand-in-cookie-password-of-32-or-more-characters",
}
