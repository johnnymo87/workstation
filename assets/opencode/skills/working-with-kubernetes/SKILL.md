---
name: working-with-kubernetes
description: Use when running any command in a company Kubernetes pod — kubectl exec, rake/rails tasks, scripts, DB queries — in production or staging, before any read-only database query (row counts, state checks, investigation) against a shared environment, when a repo recipe queries through an app's connection string or issues a session SET, or when a pod or cluster seems unreachable with plain kubectl. Covers which database login to use for read-only queries, an internal `ba` CLI estate, an Azure AKS estate, and generic clusters (exec, kubectl cp, distroless debugging, kubeconfig management). Which CLI, kubeconfig, and namespace each repo uses lives in INTERNAL.md beside this SKILL.md — read it before concluding any pod is unreachable.
---

# Working with Kubernetes (Generic Patterns)

Generic kubectl patterns that work with any Kubernetes cluster.

For internal tooling (custom CLI wrappers, environment mappings, kubeconfig conventions, gRPC/Kafka/database workflows), see [INTERNAL.md](INTERNAL.md) in this skill directory. It is fetched from Confluence during home-manager activation and contains environment-specific configurations that can't be stored in source control. If the file is missing, run `home-manager switch` to fetch it (requires Atlassian env vars).

## Read-Only Database Queries: Use the Read-Only Role

For any read-only query (counts, state checks, investigation) against a shared PostgreSQL
database behind a pooler such as PgBouncer (dev, UAT, staging, prod), log in as the database's **read-only role**, usually
`analyst`. The application's login is usually the cluster admin: one mistaken statement
writes, and through the pooler its session state reaches live traffic. A leaked
`SET default_transaction_read_only = on` has already failed production writes.

1. **Find the read-only role**, the schemas it can read, and where its credential lives
   for this cluster and environment: INTERNAL.md first, then the repo's DB skill.
2. **Connect on 5432** (the coordinator), never the pooler port (6432) that app
   connection strings use. Mount the credential into the pod (`envFrom` /
   `secretKeyRef`); don't decode it into your shell.
3. **Scope everything to the transaction:**
   ```sql
   BEGIN TRANSACTION READ ONLY;
   SET LOCAL statement_timeout = '30s';
   SELECT ...;
   COMMIT;
   ```
   Read-only mode comes only from `BEGIN TRANSACTION READ ONLY`. `SET LOCAL` is for
   timeouts: `SET LOCAL default_transaction_read_only = on` does **not** protect the
   current transaction. Never issue a session-level `SET` through a pooler, under any
   login. `PGOPTIONS="-c default_transaction_read_only=on"` is acceptable on a direct
   5432 connection only; confirm with `SHOW transaction_read_only`. Don't assume the
   role carries its own timeouts.
4. **Read-only credential unreachable from this host, or it lacks the schema you need?**
   Fall back to the app's login with exactly the shape of steps 2–3: 5432, read-only
   transaction, `SET LOCAL` only. Say in your report that you used the app's login and
   why. If you can't meet that shape (no route to 5432, a tool that sends session
   `SET`s through the pooler), stop and ask the human.
5. **Recipes that connect through the app's connection string (6432) or issue a bare
   `SET` are out of date for reads**, whether they're in a repo skill, INTERNAL.md or a
   teammate's script. This section overrides them. A `$READONLY_DATABASE_URL` may still
   point at the pooler; swap the port. Mention the stale recipe in your report.

Writes (migrations, repairs, backfills) use the app's login only when the human has
approved the write, and follow steps 2–3 too (5432, `BEGIN`, `SET LOCAL`), minus `READ ONLY`.

| Rationalization | Why it fails |
|---|---|
| "The app's login is right there, I'll skip looking up the read-only role" | The fallback is for when the read-only credential is unreachable, not inconvenient. Check step 1 first. |
| "It's a one-off; `SET default_transaction_read_only` then my SELECTs" | That session `SET` is the exact statement that has taken production read-only. Use `BEGIN TRANSACTION READ ONLY`. |
| "The JDBC URL's port is the right one" | It points at the pooler. Replace it with 5432. |
| "It's only UAT" | UAT is shared; a leaked `SET` breaks every team on it. |

## Database Query via File Transfer

Runs as the app's own `$DATABASE_URL`: approved writes only, after swapping the pooler port for 5432 and scoping settings with `BEGIN` / `SET LOCAL` (steps 2–3 above). Reads use the section above.

Distroless containers don't have interactive shells and pipes hang. Use file transfer instead:

```bash
# 1. Create query locally
cat > query.sql << 'EOF'
SELECT COUNT(*) FROM users WHERE created_at > NOW() - INTERVAL '7 days';
EOF

# 2. Get pod name
POD=$(kubectl get pods -n <namespace> --selector=app=<app-name> \
  -o jsonpath='{.items[0].metadata.name}')

# 3. Copy, execute, retrieve
kubectl cp query.sql $POD:query.sql -n <namespace>
kubectl exec $POD -n <namespace> -- psql $DATABASE_URL -f query.sql > results.txt
kubectl cp $POD:results.txt results.txt -n <namespace>

# 4. Read results
cat results.txt
```

## Debugging Distroless Containers

Distroless images have no shell or debugging tools. Use ephemeral containers:

```bash
# Create debug copy with ubuntu image
kubectl debug <pod-name> -n <namespace> -it \
  --image=ubuntu --share-processes --copy-to=debug-<pod-name>

# Inside debug container
ps aux                    # Inspect original container's processes
ls -la /proc/1/root/app   # Access original container's filesystem
```

## kubeconfig Management

```bash
# Use specific kubeconfig
kubectl --kubeconfig=/path/to/config get pods

# Set via environment (use ABSOLUTE paths, not ~/)
export KUBECONFIG=/Users/you/.kube/config-prod

# Confirm which cluster you are on before any prod command
kubectl config current-context
```

## Troubleshooting

### "Error from server (Forbidden)"
Wrong permissions or kubeconfig. Check:
```bash
kubectl auth can-i get pods -n <namespace>
```

### kubectl cp fails with permission denied
Try `/tmp/` as destination:
```bash
kubectl cp query.sql <pod>:/tmp/query.sql -n <namespace>
```

## Best Practices

1. **Always specify namespace** (`-n <namespace>`)
2. **Use selectors over pod names** -- pod names change with deployments
3. **Absolute paths in KUBECONFIG** -- `~/` doesn't expand in all contexts
4. **File transfer for complex queries** -- don't pipe large outputs through kubectl exec
5. **Clean up after debugging** -- remove debug pods and copied files
