# Claude Code Usage Monitoring

Lets the company see how its Claude Code accounts are used across developer devices, without collecting activity from anyone's personal Claude account.

## Accounts

**Company Account**:
A Claude account the company pays for, listed by email in the Company Account allowlist kept in the server's private settings.
_Avoid_: Work account, org account

**Personal Account**:
Any Claude account not on the Company Account allowlist. Its usage is never kept, even when it is used on a company Device.
_Avoid_: Private account

## Devices

**Device**:
One developer Mac that has the monitoring rollout installed, identified by its hardware serial number. The main unit for reporting usage; its hostname is only a display label.
_Avoid_: Machine, host, laptop

**Developer Mapping**:
An optional link from a Device to the person who uses it, added only when per-person reporting is needed.
_Avoid_: User mapping, owner
