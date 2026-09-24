# Security

diskvet only runs `SELECT` queries on `system.*` tables, with `readonly=2` (or
`readonly=1`), and sends nothing anywhere: see "What it reads, and what it never
reads" in the [README](README.md).

If you find a way to make it read product data, change anything, or leak a
secret (for example the salt or a password), please report it privately via
[GitHub's private vulnerability reporting](https://github.com/Protemir/diskvet/security/advisories/new)
instead of a public issue.
