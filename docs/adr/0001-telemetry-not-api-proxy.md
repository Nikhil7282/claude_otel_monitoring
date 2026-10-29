# Monitor with Claude Code's OpenTelemetry export, not an API proxy

The first request was for a proxy between Claude Code and Anthropic. We rejected it because Company Accounts are Max subscriptions, which sign in with OAuth rather than API keys. Sending those logins through our own proxy is not a supported setup and puts the accounts at risk, and an LLM gateway such as LiteLLM can only track spend for API keys anyway. Instead, each Device exports Claude Code's built-in OpenTelemetry metrics to our own Collector. Traffic to Anthropic is left untouched.

## Consequences

- We see usage metrics (cost, tokens, active time, lines of code, commits and PRs) but cannot block or rate-limit requests.
- If the Collector goes down we lose data, but developers keep working.
- If the company later moves to API-key billing, a gateway becomes an option again.
