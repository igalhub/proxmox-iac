# Locally vendored CRD schemas

`validate-manifests.sh` validates CRD-based manifests (SealedSecret,
`postgresql`, `OperatorConfiguration`, MetalLB's
`IPAddressPool`/`L2Advertisement`, ArgoCD's `Application`) against
schemas from the community
[datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog),
fetched at validation time — not vendored, so it always reflects
whatever that project currently publishes. `CustomResourceDefinition`
objects themselves (the ones charts like ArgoCD/Longhorn/MetalLB bundle
to install their own CRDs) have no schema in any catalog — that's a
known, documented kubeconform gap (`apiextensions.k8s.io` types aren't
in the standard K8s OpenAPI schema set this tooling is generated from),
handled via `-ignore-missing-schemas` rather than treated as a failure.

Two exceptions are vendored here because the upstream catalog's copies
are stale relative to what this cluster's Zalando postgres-operator CRDs
actually accept — both confirmed directly against the live cluster
(2026-08-04), both patched with only the specific stale subtree
replaced, everything else identical to the catalog's own conversion:

- **`acid.zalan.do/postgresql_v1.json`** — the catalog's `version` enum
  only allows `13`-`17`; the live `postgresqls.acid.zalan.do` CRD allows
  `14`-`18`, and this cluster runs Postgres 18
  (`k8s/postgres-operator/postgresql-cr.yaml`, verified live in PX-009).
- **`acid.zalan.do/operatorconfiguration_v1.json`** — the catalog's
  `configuration.logical_backup` subtree (and `configuration` itself)
  is missing several fields the chart's own default
  `OperatorConfiguration` CR sets
  (`logical_backup_failed_jobs_history_limit`,
  `enable_maintenance_windows`, others) — not something this repo's own
  `values.yaml` configures, purely the chart's shipped defaults using a
  newer field set than the catalog snapshot knows about.

`validate-manifests.sh` checks these local copies first, before falling
back to the upstream catalog for every other CRD kind.

**If the live CRDs' schemas change again** (an operator upgrade, a new
allowed field/value), re-export and re-patch:

```bash
kubectl get crd postgresqls.acid.zalan.do \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.postgresql.properties.version}'

kubectl get crd operatorconfigurations.acid.zalan.do \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.configuration}'
```

and update the corresponding local file to match.
