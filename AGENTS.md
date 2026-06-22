# Repository Guidance

## Container Workflow

Use Docker for Debian validation when changing `install-xray.sh`.

```bash
docker build -f Dockerfile.test -t v2ray-tools-test .
docker run --rm v2ray-tools-test bash tests/debian_integration.sh
```

Run local checks before Docker when possible:

```bash
bash -n install-xray.sh tests/install_xray_test.sh
bash tests/install_xray_test.sh
```
