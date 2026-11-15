# nginx is the only front door, on a VM and on Kubernetes

The stack had two front doors: Caddy for an empty server and the host's nginx for a server that already runs nginx. Two front doors meant two runbooks, two templates and two front-door tests for the same job. We now keep only nginx. On a VM, the host's nginx terminates TLS with a certbot certificate and proxies to the stack on localhost-only ports. On Kubernetes, a standard `Ingress` for ingress-nginx does the same, with cert-manager issuing the certificate.

Kubernetes is offered only for teams that already run a cluster. A new deployment goes on a single VM: the stack is one Prometheus with local storage, so a cluster adds parts and cost without adding availability.

## Consequences

- A fresh VM needs `nginx`, `certbot` and `python3-certbot-nginx` installed, a step Caddy didn't need.
- The DNS records must exist before the certificate step, because Let's Encrypt checks them (HTTP-01). certbot doesn't retry the way Caddy did.
- ingress-nginx was retired in March 2026 and gets no more security fixes. Clusters on another controller (F5 NGINX, Gateway API, ALB) change the gRPC annotation or route themselves.
