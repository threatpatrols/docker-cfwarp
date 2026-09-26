# docker-cfwarp

Run [Cloudflare WARP](https://1.1.1.1/) in Docker, route docker service traffic via Cloudflare WARP acting as NAT and expose a
SOCKS5/HTTP proxy using [GOST](https://github.com/ginuerzh/gost)

This is a fork of the very awesome [cmj2002/warp-docker](https://github.com/cmj2002/warp-docker) with small improvements and packaged as a smaller image.

## Docker Pull
```shell
docker pull ghcr.io/threatpatrols/docker-cfwarp:latest
```

## Github Container Repo
* https://github.com/threatpatrols/docker-cfwarp/pkgs/container/docker-cfwarp

## Usage

`docker-compose.yml`:

```yaml
services:
  warp:
    image: ghcr.io/threatpatrols/docker-cfwarp:latest
    container_name: warp
    restart: always
    # add removed rule back (https://github.com/opencontainers/runc/pull/3468)
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=2
      # - WARP_LICENSE_KEY= # optional
      # - WARP_ENABLE_NAT=1 # enable nat
    cap_add:
      # Docker already has these, they are for podman users
      - MKNOD
      - AUDIT_WRITE
      # required by warp for both podman and docker
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./data:/var/lib/cloudflare-warp
```

Start it:

```bash
docker compose up -d
```

Check it works:

```bash
curl --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace
```

If the output contains `warp=on` or `warp=plus`, WARP is connected.

## Configuration

- `WARP_SLEEP` - seconds to wait for the WARP daemon to start (default `2`).
- `GOST_ARGS` - arguments passed to GOST (default `-L :1080`).
- `WARP_LICENSE_KEY` - optional WARP+ license key.
- `WARP_ENABLE_NAT` - set to run as a NAT gateway.
- `BETA_FIX_HOST_CONNECTIVITY` - set to add host-connectivity checks and fixes.
- `REGISTER_WHEN_MDM_EXISTS` - set to register a consumer account even when `mdm.xml` exists.

Data is persisted in the `./data` volume. Delete it to re-register, for example after
changing `WARP_LICENSE_KEY`.

## Image tags

Tags use the format `{WARP_VERSION}-{GOST_VERSION}`, e.g. `2026.7.1377.0-2.12.0`.
`latest` always points at the most recent build.

## Building

The `Build and publish Docker image` workflow builds and pushes to ghcr.io. To build
locally:

```bash
docker build -t docker-cfwarp .
```

## Further reading

- [docs/](docs/README.md)
- How it works from the original author Caomingjun: [blog post](https://blog.caomingjun.com/run-cloudflare-warp-in-docker/en/#How-it-works).
