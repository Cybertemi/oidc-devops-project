# Build Log — OIDC / CDN / Certificate Management Project

A running log of what was built, what broke, and how it was diagnosed —
kept as raw material for a future writeup (Medium/LinkedIn), not a polished
document itself.

---

## Project Summary

**Goal:** learn OIDC (used two ways — GitHub Actions → AWS, and IRSA inside
Kubernetes), CDN (CloudFront), and certificate management (cert-manager on
EKS) by building a real, working deployment.

**Stack:** Terraform (modular, remote state in S3 + DynamoDB lock) → shared
EKS cluster → GitHub Actions OIDC → IRSA → cert-manager → NGINX Ingress →
CloudFront.

**Repo:** https://github.com/Cybertemi/oidc-devops-project

---

## Phase 0 — Bootstrap (remote state)

Created a standalone Terraform config (`bootstrap/`) to provision:
- S3 bucket: `temitope-oidc-terraform-state-bucket` (versioned, encrypted, public access blocked)
- DynamoDB table: `terraform-state-locks` (state locking, PAY_PER_REQUEST billing)

This has no backend of its own — chicken-and-egg problem, since it's the
thing creating the backend everything else uses.

**Status:** ✅ Applied successfully.

---

## Phase 1 — Decision: shared cluster vs per-environment clusters

Originally planned dev/staging/prod as three separate Terraform-managed
VPCs + potentially three EKS clusters. Reconsidered for cost reasons —
EKS control plane billing is per-cluster (~$0.10/hr), and running three
continuously during a multi-week build/interview-prep period adds up.

**Decision:** one shared EKS cluster (`shared-eks-cluster`), with
dev/staging/prod implemented as **Kubernetes namespaces**, not separate
AWS infrastructure. Talking point for interviews: namespace isolation is
a real production pattern at cost-conscious companies; tradeoff is
reduced blast-radius isolation vs full multi-cluster.

Destroyed the three original per-environment VPCs (`dev`, `staging`,
`prod` Terraform stacks) once this decision was made, to avoid paying for
unused infrastructure.

---

## Phase 2 — Networking + EKS (`environments/platform`)

Built `modules/networking` (VPC, public/private subnets across 2 AZs, NAT
gateway, IGW, route tables) and `modules/eks` (cluster, node IAM role,
cluster IAM role, managed node group, and — critically — the cluster's own
**OIDC issuer**, registered as a trusted IAM OIDC provider for later IRSA use).

**Issue hit:** `kubernetes_version = "1.29"` failed with
`InvalidParameterException: unsupported Kubernetes version`. AWS ages out
EKS versions faster than expected (~14 month support window). Fixed by
leaving `kubernetes_version` unset (`null`) so AWS uses its current default
supported version — more future-proof than pinning.

**Status:** ✅ Applied. Cluster live:
- `cluster_name = shared-eks-cluster`
- `oidc_issuer_url = https://oidc.eks.us-east-1.amazonaws.com/id/0CA2B41DCEF8AC29F5D775C6A5843431`

---

## Phase 3 — GitHub Actions OIDC (`modules/github-oidc`)

IAM OIDC provider trusting `token.actions.githubusercontent.com`, plus an
IAM role whose trust policy's `sub` claim condition is scoped to
`repo:Cybertemi/oidc-devops-project:ref:refs/heads/main` — meaning only
workflow runs from that exact repo and branch can assume the role. Forked
repos or other branches get denied at the STS level, before any AWS
permission is even evaluated.

**Issue hit:** hardcoded GitHub thumbprint had a typo (39 hex chars
instead of 40 → invalid). Fixed by fetching the thumbprint dynamically via
a `tls_certificate` data source instead of hardcoding a value that can
also go stale if GitHub ever rotates certs.

**Status:** ✅ Applied.
`github_actions_role_arn = arn:aws:iam::026090550076:role/oidc-devops-github-actions-role`

---

## Phase 4 — IRSA, real-world example (EBS CSI driver)

Original plan was Route53-scoped IRSA (for cert-manager DNS-01). Switched
to HTTP-01 + DuckDNS after deciding not to purchase a domain (see below),
which removed the need for Route53 permissions. Rather than drop the IRSA
lesson, repurposed it onto the **EBS CSI driver** — arguably a *more*
realistic example, since it's a genuine production pattern (a cluster
controller needing scoped AWS permissions, not a contrived demo).

Built: IRSA trust policy scoped to
`system:serviceaccount:kube-system:ebs-csi-controller-sa`, IAM role,
`AmazonEBSCSIDriverPolicy` attachment, and the `aws-ebs-csi-driver` EKS
addon itself.

Also created a proper `StorageClass` (`ebs-csi-gp3`) using the CSI
provisioner (`ebs.csi.aws.com`) rather than the deprecated in-tree
provisioner (`kubernetes.io/aws-ebs`) that ships as EKS's `gp2` default.

**Status:** ✅ Addon `ACTIVE`, StorageClass created and set as default.

---

## Phase 5 — Domain decision: DuckDNS instead of a purchased domain

Couldn't justify the cost of a domain right now. DuckDNS doesn't support
Route53-style DNS-01 validation, so switched cert-manager's `ClusterIssuer`
to **HTTP-01** instead — no AWS DNS permissions needed, works with any
publicly-reachable domain including free ones.

**Tradeoff documented:** CloudFront (Phase 7) won't get a pretty custom
domain via ACM without a real DNS-owned domain — will use its default
`*.cloudfront.net` address instead. Documented as an explicit,
understood tradeoff rather than an oversight.

Domain used: `devops-oidc.duckdns.org`

---

## Phase 6 — NGINX Ingress Controller + cert-manager

Installed via Helm:
- `ingress-nginx` (namespace `ingress-nginx`) — provisions an AWS Classic
  ELB as the cluster's public entry point
- `cert-manager` (namespace `cert-manager`, with CRDs) — `ClusterIssuer`
  `letsencrypt-http01` created, using HTTP-01 solver against
  `ingressClassName: nginx`

Pointed DuckDNS at the ELB's resolved IP (`3.211.63.232`) via `nslookup`
+ DuckDNS's update API, since DuckDNS's free tier only accepts a plain IP,
not the ELB's hostname. **Known limitation:** AWS ELB IPs can rotate;
DuckDNS would need re-pointing if that happens (acceptable for a
short-lived demo project, would use Route53 alias records or a static
IP/NLB in production to avoid this).

**Status:** ✅ ClusterIssuer `READY = True`.

---

## Phase 7 — First certificate issuance: debugging session

Deployed a full Nextcloud stack (`kefaslungu/hng-nextcloud` image +
MariaDB + PersistentVolumeClaims on the new `ebs-csi-gp3` StorageClass)
into the `dev` namespace, with an Ingress annotated for
`cert-manager.io/cluster-issuer: letsencrypt-http01`.

### Attempt 1 — failed: "order is in invalid state"

Diagnosed via `kubectl describe certificate` → `kubectl get order` →
`kubectl describe challenge`. Found the HTTP-01 solver pod losing its
Kubernetes Service endpoint mid-validation
(`Service dev/cm-acme-http-solver-2ffb2 does not have any active
Endpoint`), likely due to the cluster being busy scheduling MariaDB +
Nextcloud + the solver pod simultaneously, causing a timing race.
Some Let's Encrypt validation requests *did* return `200` in the ingress
logs during this window, but the order still failed — consistent with a
race rather than a hard config error.

**Fix attempted:** waited for MariaDB/Nextcloud to reach stable `Running`
state first, then deleted the stuck `Certificate`/`Challenge`/`Order` and
retried clean.

### Attempt 2 — failed differently: CAA DNS timeout

\```
Error accepting authorization: acme: authorization error for
devops-oidc.duckdns.org: 400 urn:ietf:params:acme:error:dns: During
secondary validation: While processing CAA for devops-oidc.duckdns.org:
DNS problem: query timed out looking up CAA for devops-oidc.duckdns.org
\```

Confirmed this was **not** a problem with the cluster, Ingress, or
cert-manager config — Let's Encrypt's multi-perspective secondary
validation was timing out querying DuckDNS's authoritative nameservers
for a CAA record, a known DuckDNS reliability quirk. Ruled out
Kubernetes-side causes first (security groups checked via `describe
security-groups`, direct `curl` to the domain over port 80 succeeded,
ingress logs showed requests reaching the solver pod correctly) before
concluding the failure was external to the cluster.

**Status:** retry in progress as of last log entry.

---

## Open items / next phases

- [ ] Confirm certificate issues successfully after CAA retry
- [ ] Verify HTTPS end-to-end in browser (padlock, Let's Encrypt issuer)
- [ ] CloudFront in front of the ELB (Phase 7 original numbering)
- [ ] GitHub Actions workflow: OIDC-authenticated `kubectl apply` / `helm upgrade` on push to `main`
- [ ] Add CloudWatch/Prometheus alert on cert-manager's certificate expiry metric
- [ ] Document final architecture diagram

### Attempt 3 — root cause identified: DuckDNS unreliable, switched to nip.io

Second failure showed a different symptom (`SERVFAIL looking up A record`,
then later `query timed out looking up A/AAAA`) despite `nslookup` from
the local machine resolving the domain correctly every time. This
confirmed the problem was specific to Let's Encrypt's **secondary
validation** — they query DNS from multiple independent geographic
vantage points (not just one), and DuckDNS's authoritative nameservers
were failing or timing out for at least one of those vantage points,
even though resolution worked fine locally. A domain "working" from your
own machine doesn't guarantee it resolves reliably from every location
on the internet — this was the key lesson here.

**Fix:** switched from DuckDNS to `nip.io`, a wildcard DNS service that
maps `<ip-with-dashes>.nip.io` directly to that IP with no DNS record to
create or propagate — e.g. `3-211-63-232.nip.io` resolves to
`3.211.63.232` instantly and consistently, since there's no authoritative
zone lookup involved the way there is with a registered subdomain.

Updated both:
- `nextcloud-ingress.yaml` (`tls.hosts`, `rules.host`)
- `nextcloud.yaml` (`NEXTCLOUD_TRUSTED_DOMAINS`)

Deleted the stuck `Certificate`/`Challenge`/`Order` objects and reapplied.

**Status:** ✅ `nextcloud-tls` certificate issued successfully,
`READY = True`. Verified in browser: valid padlock, Let's Encrypt as
issuer, Nextcloud login page loading over HTTPS at
`https://3-211-63-232.nip.io`.

**Known limitation carried forward:** like DuckDNS, this still ties the
domain to the ELB's current IP — if the underlying AWS Load Balancer's IP
rotates, the nip.io-based hostname breaks and needs updating. In
production, this would be solved with a real domain + Route53 alias
record pointing at the ELB by name, which AWS keeps in sync automatically
regardless of IP changes underneath.

---

## Phase 8 — Multi-environment strategy: Kustomize + branch-based promotion

Initially planned three separate copies of the k8s manifests (one per
environment) but reconsidered — duplicated YAML across dev/staging/prod
risks silent drift (a fix applied to one environment's copy but forgotten
in the others). Adopted **Kustomize** instead: one shared `base/` defining
the application (Nextcloud + MariaDB + Ingress + Secret), with three thin
`overlays/` (dev, staging, prod) that only override what's genuinely
environment-specific — namespace, hostname, and credentials.

**Hostname strategy:** used nip.io's subdomain-prefix support to get three
distinct hostnames from one IP with zero DNS setup — `dev.<ip>.nip.io`,
`staging.<ip>.nip.io`, and the bare `<ip>.nip.io` for prod (no prefix =
production, a deliberate convention). CloudFront's domain was added as a
second Ingress, scoped to `prod` only.

### Issue: deprecated `patchesStrategicMerge` field

Kustomize warned this field is deprecated in favor of `patches:`. Migrated
all three overlays to the new syntax
(`patches: - path: file.yaml` instead of `patchesStrategicMerge: - file.yaml`).

### Issue: empty patch file misidentified as a JSON6902 patch