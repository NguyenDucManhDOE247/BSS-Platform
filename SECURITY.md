# Security Policy

## Supported Versions

This is a learning / reference project. Only the `main` branch receives security updates.

| Version | Supported |
|---|---|
| `main` (latest) | ✅ |
| Tagged releases | ❌ best-effort only |

## Reporting a Vulnerability

If you discover a security issue in this repo, **please do not open a public GitHub issue**.

Email the maintainer at **gemmy94bkhn@gmail.com** with:

- A description of the vulnerability and its impact.
- Steps to reproduce (PoC welcome).
- Affected file(s) / service(s) / commit SHA.
- Your name / handle for credit (optional).

You can expect:

- **Acknowledgement** within 72 hours.
- An initial assessment within 7 days.
- A patch or mitigation plan communicated back to you before any public disclosure.

## Scope

In-scope:

- Application code in `apps/backend/**` and `apps/frontend/**`.
- Infrastructure-as-Code in `infrastructure/terraform/**` and `infrastructure/kubernetes/**`.
- CI/CD workflows in `.github/workflows/**` (e.g. permission misconfigurations).

Out-of-scope:

- Vulnerabilities in third-party dependencies (please report upstream and open an issue here to bump the version).
- Issues that require an attacker with cluster-admin access on the user's own machine.
- Theoretical attacks without a working PoC.

## Security Practices Already in Place

- ✅ No AWS access keys in repo — authentication via IRSA + GitHub OIDC.
- ✅ Trivy image scanning in CI (fails on HIGH / CRITICAL).
- ✅ Pods run `runAsNonRoot`, `readOnlyRootFilesystem`, drop all capabilities.
- ✅ ECR repos use immutable tags.
- ✅ Secrets sourced from AWS Secrets Manager via Secrets Store CSI Driver.
- ✅ EKS public endpoint restricted in `prod`.

Thanks for helping keep the project safe.
