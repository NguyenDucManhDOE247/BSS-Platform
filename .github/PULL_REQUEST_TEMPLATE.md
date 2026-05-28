<!--
Thanks for the contribution! Please fill in the sections below.
For the commit / PR title, follow Conventional Commits:
  <type>(<scope>): <imperative summary>
-->

## Summary

<!-- 1-3 bullets describing what changed and why. -->

-
-

## Type of change

- [ ] Bug fix (non-breaking, fixes an issue)
- [ ] New feature (non-breaking)
- [ ] Breaking change (would change existing API / schema / contract)
- [ ] Refactor (no behavior change)
- [ ] Docs only
- [ ] Infra / CI

## Affected services

<!-- Tick what you touched so reviewers / CI know what to focus on. -->

- [ ] `customer-service`
- [ ] `product-catalog`
- [ ] `order-management`
- [ ] `billing-service`
- [ ] `api-gateway`
- [ ] `web-portal`
- [ ] `admin-console`
- [ ] Terraform / AWS infra
- [ ] Kubernetes manifests
- [ ] CI/CD pipelines
- [ ] Shared packages

## How to test

<!-- Step-by-step commands or scenarios. Include curl / screenshots / API calls. -->

```bash
# example
make local-up
cd apps/backend/customer-service && mvn verify
```

## Checklist

- [ ] My code follows the conventions in [`CONTRIBUTING.md`](../CONTRIBUTING.md).
- [ ] I added / updated tests where appropriate.
- [ ] I updated docs (`README.md`, `docs/SETUP.md`, ADR if architectural).
- [ ] I did **not** commit secrets, AWS account IDs, or production domain names.
- [ ] If infra: I called out cost-impacting resources in the summary above.
- [ ] CI is green on this branch.

## Related issues

Closes #
