---
name: Working with Kubernetes (Generic Patterns)
description: Generic kubectl patterns for pod interaction, file transfer, debugging distroless containers, and kubeconfig management. Works with any Kubernetes cluster. For environment-specific configurations, see the companion skill fetched from Confluence.
---

# Working with Kubernetes (Generic Patterns)

Generic kubectl patterns that work with any Kubernetes cluster. For environment-specific configurations and internal tooling, see the companion file [INTERNAL.md](INTERNAL.md) in this skill directory (fetched from Confluence during home-manager activation).

## Executing Commands in Pods

```bash
# Single command
kubectl exec <pod-name> -n <namespace> -- <command>

# Interactive shell (if available)
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# Specific container (multi-container pod)
kubectl exec <pod-name> -c <container-name> -n <namespace> -- <command>
```

## Finding Pods

```bash
# By label selector (stable across deploys)
kubectl get pods --selector=app=<app-name> -n <namespace>

# First pod matching selector (for scripting)
kubectl get pods -n <namespace> --selector=app=<app-name> \
  -o jsonpath='{.items[0].metadata.name}'

# Pod details
kubectl describe pod <pod-name> -n <namespace>
```

## File Transfer

```bash
# Copy to pod
kubectl cp <local-file> <pod-name>:<remote-path> -n <namespace>

# Copy from pod
kubectl cp <pod-name>:<remote-path> <local-file> -n <namespace>

# From specific container
kubectl cp <pod-name>:<remote-path> <local-file> -n <namespace> -c <container-name>
```

## Database Query via File Transfer

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

# Check current context
kubectl config current-context

# Switch context
kubectl config use-context <context-name>

# List all contexts
kubectl config get-contexts
```

## Copy File to Multiple Pods

```bash
PODS=$(kubectl get pods -n <namespace> --selector=app=<app-name> \
  -o jsonpath='{.items[*].metadata.name}')

for POD in $PODS; do
  kubectl cp config.json $POD:/app/config.json -n <namespace>
  echo "Copied to $POD"
done
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

### Can't find pod name
```bash
kubectl get pods -n <namespace>
kubectl get pods -n <namespace> --selector=app=<app-name>
```

## Best Practices

1. **Always specify namespace** (`-n <namespace>`)
2. **Use selectors over pod names** -- pod names change with deployments
3. **Absolute paths in KUBECONFIG** -- `~/` doesn't expand in all contexts
4. **File transfer for complex queries** -- don't pipe large outputs through kubectl exec
5. **Clean up after debugging** -- remove debug pods and copied files

## Environment-Specific Documentation

For internal tooling (custom CLI wrappers, environment mappings, kubeconfig conventions, gRPC/Kafka/database workflows), see [INTERNAL.md](INTERNAL.md) in this skill directory.

This companion file is fetched from Confluence during home-manager activation and contains environment-specific configurations that can't be stored in source control. If the file is missing, run `home-manager switch` to fetch it (requires Atlassian env vars).
