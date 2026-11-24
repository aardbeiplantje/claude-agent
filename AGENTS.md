# AGENTS.md

Notes for coding agents working on this repository. The policy that goes into the
containers is `config/claude-code/AGENTS.md`, a different file.

## Layout

- `Dockerfile`: one `base` stage, then the targets `rocm`, `bash` (basic), `dev` (full),
  `arduino`, `android` and `web`.
- `docker-bake.hcl`: build definitions. The `local` group is what `docker buildx bake` builds.
- `run.sh`: starts a container for the current directory. It builds the image first when it is
  missing or was built for the other architecture.
- `config/claude-code/`: copied to `/etc/claude-code/` in every image.

## Platform

- `DOCKER_PLATFORM` (environment variable) selects `linux/amd64` or `linux/arm64`. Bake
  defaults to amd64. `run.sh` defaults to the host's architecture.
- `rocm` and `android` are amd64 only. Do not give them an arm64 platform, and keep
  `run.sh` refusing arm64 for them.
- Use the existing `DOCKER_PLATFORM` name. Do not add another variable for the same thing.

## Checks

- After editing `run.sh`, run `bash -n run.sh`.
- After editing `docker-bake.hcl`, check that it parses as HCL. Run `docker buildx bake --print`
  when Docker is available.
- Docker is not always available in the sandbox. Say so when a build was not run.

## Git

- Commit to the checked-out branch. Do not create or switch branches unless the user asks.
