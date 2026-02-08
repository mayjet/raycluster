README - Ray + Consul cluster

1) Build image:
```bash
docker build -t registry.example.com/project:py311-uv project/docker
docker push registry.example.com/project:py311-uv
```

2) Start Consul servers on 3 chosen VMs:
```bash
scp project/consul/server-compose.yml vm1:~
ssh vm1 'docker compose -f server-compose.yml up -d'
... repeat on vm2, vm3
```

3) Start clients (each VM)
```bash
edit consul/client-compose.yml to set CONSUL_SERVER_1/2/3 IPs and image tag
docker compose -f consul/client-compose.yml up -d
```

4) Check Consul UI: `http://<serverip>:8500` -> Services should show ray-head when promoted.

5) Jupyter: enable by ENV JUPYTER=yes on image/container.

Security:
 - Provide `/root/.ssh/authorized_keys` via a volume and disable password auth (Dockerfile sets it).
 - Do not expose Jupyter without auth in production.