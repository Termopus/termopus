# Contributing to Termopus

Thanks for your interest in contributing! This guide will help you get started.

## Getting Started

1. **Fork** the repo and clone your fork
2. Create a feature branch: `git checkout -b my-feature`
3. Make your changes
4. Push and open a **Pull Request**

## Development Setup

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Node.js | 18+ | [nodejs.org](https://nodejs.org/) |
| Flutter | 3.11+ | [flutter.dev](https://docs.flutter.dev/get-started/install) |
| Rust | Latest stable | [rustup.rs](https://rustup.rs/) |
| wrangler | Latest | `npm install -g wrangler` |

### Running Locally

```bash
# Backend (Cloudflare Workers)
cd relay_worker && npm install && npx wrangler dev --env dev
cd provisioning_api && npm install && npx wrangler dev --env dev

# Mobile app
cd app && flutter pub get && flutter run

# Bridge
cd bridge && cargo build && cargo run -- --relay wss://localhost:8787
```

## Project Structure

| Directory | Language | What it does |
|-----------|----------|--------------|
| `app/` | Dart (Flutter) | Mobile app — iOS & Android |
| `bridge/` | Rust | Desktop agent that sits next to Claude Code |
| `relay_worker/` | TypeScript | Cloudflare Durable Object — WebSocket relay |
| `provisioning_api/` | TypeScript | Cloudflare Worker — device provisioning & mTLS |
| `scripts/` | Bash | Setup and deployment automation |

## Guidelines

- **Follow existing patterns** — match the style of the code around your changes
- **Keep PRs focused** — one feature or fix per PR
- **Test your changes** — make sure builds pass (`flutter build`, `cargo build`, `npm run build`)
- **Write clear commit messages** — describe *why*, not just *what*

## Reporting Bugs

Open an [issue](https://github.com/Termopus/termopus/issues/new?template=bug_report.yml) with:
- Steps to reproduce
- Expected vs. actual behavior
- Platform (iOS/Android, macOS/Linux) and versions

## Requesting Features

Open a [feature request](https://github.com/Termopus/termopus/issues/new?template=feature_request.yml) describing your use case and proposed solution.

## Security

Found a vulnerability? **Do not open a public issue.** See [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## License

By contributing, you agree that your contributions will be licensed under the [AGPL-3.0 License](LICENSE).
